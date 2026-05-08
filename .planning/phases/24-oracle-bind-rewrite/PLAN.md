# Phase 24 - Oracle Bind Transparent Rewriter

**Milestone:** v1.4
**Status:** Planned r1 narrow fold, ready for plan-gate r2
**Date:** 2026-05-08
**Requirement:** Oracle bind names containing `$` or `#` must run through go-ora without forcing user-visible placeholder renames.
**Reference:** `.planning/phases/24-oracle-bind-rewrite/24-CONTEXT.md`

## Goal

Phase 24 changes the Oracle bind contract from "reject Oracle-legal `$` / `#` names because go-ora cannot parse them" to "accept Oracle-legal user bind names and transparently rewrite them at the adapter boundary before go-ora sees SQL or named args." User SQL such as `SELECT :my$1 FROM dual` remains user-facing as `my$1`; the Oracle adapter rewrites it to a driver-safe `my_x24_1` internally, executes through go-ora, and reverse-maps colon-prefixed driver bind names back to the original name.

The r1 fold closes the plan-gate issues: q-quote delimiter rules are fully locked, user bind grammar rejects leading `$` / `#`, sentinel and driver-name collision detection are case-insensitive, cursor-marker detection uses the same code-region scanner as bind rewriting, SQL-capture tests prove every driver boundary receives rewritten SQL, rewrite work is precomputed before the Oracle session mutex, and rewrite performance has strict budget coverage.

## Scope

Phase 24 contains one executable sub-plan:

| Wave | Plan | Objective | Depends On |
| --- | --- | --- | --- |
| 1 | `24-01-PLAN.md` | Add Oracle user-bind tokenizer/rewriter, split user/driver validation, rewrite named args and cursor params, reverse-map errors, and update Phase 22 audit/test sentinels. | Phase 22 + 22.5 shipped |

Implementation scope note: the prompt's approximate six-file list is expanded to eight files because current Phase 22 tests in `oracle_driver_context_test.go` and `oracle_refcursor_test.go` explicitly assert `$` / `#` rejection and must be updated for the new contract.

## Inputs Read

- `.planning/phases/22-oracle-correctness/PLAN.md`
- `.planning/phases/22-oracle-correctness/22-CONTEXT.md`
- `.planning/phases/22-oracle-correctness/22-01-PLAN.md`
- `.planning/phases/23-folder-scoped-notes/PLAN.md`
- `.planning/phases/23-folder-scoped-notes/23-CONTEXT.md`
- `.planning/phases/23-folder-scoped-notes/23-01-PLAN.md`
- `dbee/adapters/oracle_driver.go`
- `dbee/adapters/oracle_refcursor.go`
- `dbee/adapters/oracle_plsql.go`
- `dbee/adapters/oracle_bind_audit_test.go`
- `dbee/adapters/oracle_driver_context_test.go`
- `dbee/adapters/oracle_refcursor_test.go`
- `dbee/adapters/oracle_driver_dbms_output_test.go`
- `Makefile`
- Oracle SQL Language Reference: Database Object Names and Qualifiers
- Oracle SQL Language Reference: Literals
- go-ora README named-parameter guidance

## Strict Markers

Strict marker target: **13 ORA24 strict markers + `PHASE24_ALL_PASS=true` rollup**. Diagnostics are emitted but not counted.

| Marker | Kind | Owner | Success Criterion |
| --- | --- | --- | --- |
| `ORA24_REWRITE_OK=true` | Strict | `oracle_bind_rewrite_test.go` | SQL placeholders containing `$` / `#` rewrite to `_x24_` / `_x23_`, while returned metadata keeps original names. |
| `ORA24_TOKENIZER_OK=true` | Strict | `oracle_bind_rewrite_test.go` | Rewriter skips single quotes, q-quotes, double-quoted identifiers, line comments, and block comments. |
| `ORA24_TOKENIZER_QQUOTE_OK=true` | Strict | `oracle_bind_rewrite_test.go` | Oracle q-quote opener/terminator rules are covered for paired delimiters, arbitrary same delimiters, invalid whitespace openers, and invalid single-quote openers. |
| `ORA24_BIND_MAP_OK=true` | Strict | `oracle_driver_context_test.go` or `oracle_bind_rewrite_test.go` | `oracleNamedArgs` transforms map keys with the same scheme as SQL rewriting and preserves sorted deterministic output. |
| `ORA24_REVERSE_ERROR_OK=true` | Strict | `oracle_bind_rewrite_test.go` | Driver errors containing rewritten names are wrapped so user-facing text contains the original bind names. |
| `ORA24_CURSOR_MARKER_DOLLAR_OK=true` | Strict | `oracle_refcursor_test.go` | `:cur$1 /*CURSOR*/` parses, rewrites for go-ora, and remains displayed as `cur$1`. |
| `ORA24_RESERVED_REJECT_OK=true` | Strict | `oracle_driver_context_test.go` | Reserved/unsafe user names such as `table`, `date`, and `user` still reject before execution. |
| `ORA24_COLLISION_REJECT_OK=true` | Strict | `oracle_bind_rewrite_test.go` | User names containing `_x24_` or `_x23_` are rejected with the locked sentinel-collision message. |
| `ORA24_PHASE22_INTERNAL_PRESERVED_OK=true` | Strict | `oracle_driver_dbms_output_test.go` or audit rollup | DBMS_OUTPUT `:p_line` / `:p_status` SQL and args remain unchanged and are not routed through rewrite. |
| `ORA24_PLSQL_ASSIGN_SKIP_OK=true` | Strict | `oracle_refcursor_test.go` | `:= /*CURSOR*/` and stray cursor comments remain non-markers and do not block DBMS_OUTPUT execution. |
| `ORA24_AUDIT_SURFACE_OK=true` | Strict | `oracle_bind_audit_test.go` | AST audit recognizes explicit user/driver validation and the rewrite path; direct unsafe `sql.Named(name, ...)` remains rejected. |
| `ORA24_PHASE22_PRESERVED_OK=true` | Strict | `oracle_bind_audit_test.go` | Phase 22 audit core, unsafe/reserved matrix, DBMS_OUTPUT lockstep, and suggestion sentinel still pass under new semantics. |
| `ORA24_REWRITE_BUDGET_OK=true` | Strict | `oracle_bind_rewrite_test.go` | Small, medium, and large rewrite cohorts meet locked wall-time and allocation budgets; no-change fast path is zero-alloc. |
| `PHASE24_ALL_PASS=true` | Rollup | `TestPhase24Rollup` | Emitted only when all Phase 24 strict helpers and Phase 22 preservation helpers pass under `ORACLE24_ROLLUP=1`. |
| `ORA24_REWRITE_MS=<n>` | Diagnostic | `oracle_bind_rewrite_test.go` | Reports rewrite/tokenizer runtime for the unit corpus. |
| `ORA24_TOKENIZER_CASES_DIAGNOSTIC=<n>` | Diagnostic | `oracle_bind_rewrite_test.go` | Reports tokenizer corpus size and skipped-region coverage. |
| `ORA24_SENTINEL_CORPUS_DIAGNOSTIC=<n>` | Diagnostic | `oracle_bind_rewrite_test.go` | Reports diagnostic-only corpus scan count for naturally occurring `_x24_` / `_x23_` sentinel substrings. |

## Decision Coverage

| Decision | Covered By | Success Criterion |
| --- | --- | --- |
| ORA24-01 | `24-01` | `$` rewrites to `_x24_`, `#` rewrites to `_x23_`, and sentinel collisions reject case-insensitively. |
| ORA24-02 / ORA24-17 | `24-01` | SQL tokenizer skips all locked literal/comment/identifier regions; q-quote opener/terminator rules are fully enumerated and tested. |
| ORA24-03 | `24-01` | Code-region bind detection uses `:([A-Za-z_][A-Za-z0-9_$#]*)`, rejecting leading `$` / `#`. |
| ORA24-04 / ORA24-23 | `24-01` | User SQL and named args are rewritten before `conn.ExecContext`, `d.c.QueryOnConn`, or PL/SQL execution reaches go-ora; rewrite precomputes before `d.mu.Lock()`. |
| ORA24-05 / ORA24-18 | `24-01` | Validation is split into user and driver surfaces; legacy `validateOracleBindName` is deleted and audit rejects reintroduction. |
| ORA24-06 / ORA24-19 | `24-01` | Only colon-prefixed rewritten names reverse-map to original names, after formatting, without losing `errors.Unwrap`. |
| ORA24-07 | `24-01` | Cursor marker detection, validation, parsing, and cleanup scan only code regions and support `$` / `#`. |
| ORA24-08 | `24-01` | Static DBMS_OUTPUT binds stay `p_`-prefixed and unchanged. |
| ORA24-09 | `24-01` | The `:= /*CURSOR*/` assignment skip and stray cursor-comment behavior remain covered. |
| ORA24-10 | `24-01` | Strict markers and diagnostics emit with the ownership table above. |
| ORA24-11 | `24-01` | AST audit is updated for user/driver validators and rewrite helpers. |
| ORA24-12 | `24-01` | Test scope is unit/mock only; no live Oracle or testcontainers dependency. |
| ORA24-13 | `24-01` | Scope fence includes the base implementation files plus existing tests that must change for the new contract. |
| ORA24-14 | `24-01` | Locked helpers remain untouched. |
| ORA24-15 | `24-01` | Phase 22/22.5 contracts remain green with exact validator error text and updated suggestion semantics. |
| ORA24-16 | `24-01` | Sentinel-collision UX uses the locked error text shape. |
| ORA24-20 | `24-01` | Rewrite performance budgets and benchmark cohorts are enforced. |
| ORA24-21 | `24-01` | Per-query rewrite path is manual byte scan only; regex is forbidden in the hot path. |
| ORA24-22 | `24-01` | Case-folding contract covers sentinels, driver-name collisions, cursor filtering, and reverse-map keys. |

## Locked Helpers Contract

UNTOUCHED:

- `lua/dbee/schema_filter_authority.lua`
- `lua/dbee/schema_name_canonical.lua`
- `lua/dbee/lsp/epoch_authority.lua`

Phase 24 is Oracle-adapter-only. It must not edit Lua LSP, schema filtering, folder notes, drawer UI, or project memory files.

## Scope Fence

Planning artifacts written in this phase:

- `.planning/phases/24-oracle-bind-rewrite/PLAN.md`
- `.planning/phases/24-oracle-bind-rewrite/24-CONTEXT.md`
- `.planning/phases/24-oracle-bind-rewrite/24-01-PLAN.md`

Implementation write-allowed files:

- `dbee/adapters/oracle_driver.go`
- `dbee/adapters/oracle_bind_rewrite.go` (new)
- `dbee/adapters/oracle_refcursor.go`
- `dbee/adapters/oracle_plsql.go`
- `dbee/adapters/oracle_bind_audit_test.go`
- `dbee/adapters/oracle_bind_rewrite_test.go` (new)
- `dbee/adapters/oracle_driver_context_test.go`
- `dbee/adapters/oracle_refcursor_test.go`

Do not edit `Makefile` in r0 unless plan-gate explicitly requests a Makefile target. The required verification command can run Phase 24 markers directly with `ORACLE24_ROLLUP=1 go -C dbee test ./adapters ...`.

## Verification Summary

Execution phase should run:

```bash
env ORACLE24_ROLLUP=1 GOCACHE=/tmp/codex-go-cache go -C dbee test ./adapters -run 'TestOracle(BindRewrite|BindName|NamedArgs|UnsafeBindNames|RefCursor|BindAudit|BindRewriteBudget)|TestFetchDBMSOutputFromConn|TestPhase22Rollup|TestPhase24Rollup' -v
env GOCACHE=/tmp/codex-go-cache go -C dbee test ./adapters -run '^$' -bench '^BenchmarkOracleBindRewrite$' -benchmem
env GOCACHE=/tmp/codex-go-cache go -C dbee test ./adapters
```

Expected marker output from the focused command includes:

```text
ORA24_REWRITE_OK=true
ORA24_TOKENIZER_OK=true
ORA24_TOKENIZER_QQUOTE_OK=true
ORA24_BIND_MAP_OK=true
ORA24_REVERSE_ERROR_OK=true
ORA24_CURSOR_MARKER_DOLLAR_OK=true
ORA24_RESERVED_REJECT_OK=true
ORA24_COLLISION_REJECT_OK=true
ORA24_PHASE22_INTERNAL_PRESERVED_OK=true
ORA24_PLSQL_ASSIGN_SKIP_OK=true
ORA24_AUDIT_SURFACE_OK=true
ORA24_PHASE22_PRESERVED_OK=true
ORA24_REWRITE_BUDGET_OK=true
PHASE24_ALL_PASS=true
```

## Threat Model

Primary risk is an unsafe SQL rewrite that edits placeholders inside string literals, quoted identifiers, comments, or diagnostic cursor comments. Phase 24 mitigates this with a manual Oracle SQL scanner and tokenizer unit corpus before any adapter integration.

Secondary risk is breaking Phase 22 by relaxing too much: reserved bind names must still reject, internal `p_` binds remain static, and AST audit still fails on direct dynamic `sql.Named` construction. Tertiary risk is confusing users with go-ora rewritten names in errors; reverse mapping is part of the execution contract, not a best-effort diagnostic.

## Concerns For Implementation Gate

- The rewriter must run before every user SQL path into go-ora and before `d.mu.Lock()`: plain query, plain exec, PL/SQL exec, and REF CURSOR PL/SQL exec.
- Current tests in `oracle_driver_context_test.go:213-218` and `oracle_refcursor_test.go:94-99` assert `$` / `#` rejection; execution must update them or broad adapter tests will fail.
- `filterCursorBindNames` must compare original cursor names before rewriting, then cursor OUT args must use rewritten driver names.
- Reverse error replacement is colon-prefixed and boundary-aware; it must not replace incidental bare substrings.
- Sentinel collision errors must reject `_x24_` and `_x23_` case-insensitively even when the name contains no `$` / `#`.
- Driver-name collisions are detected with uppercase-folded driver names because go-ora compares bind names case-insensitively.
- Do not keep a compatibility `validateOracleBindName`; delete it and force all call sites to choose user or driver validation.
- Implement SQL capture in tests for all four execution boundaries; args-only capture is insufficient.
