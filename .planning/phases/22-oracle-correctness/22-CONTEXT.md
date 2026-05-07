# Phase 22: Oracle Correctness - Context

**Gathered:** 2026-05-07
**Revision:** r3 narrow fold after plan-gate r3
**Status:** Ready for execute
**Source:** Re-scoped Phase 22 prompt, local code audit, Oracle docs, project memory validation, plan-gate r1/r2/r3 findings

<domain>
## Phase Boundary

Phase 22 closes one Oracle correctness class: Oracle bind names that collide with Oracle SQL reserved words, PL/SQL reserved words/keywords, or project-learned parser-risk names and trigger errors such as `ORA-01745: invalid host/bind variable name`.

In scope:
- Rename internal DBMS_OUTPUT binds in `dbee/adapters/oracle_driver.go` from `line/status` to `p_line/p_status` in both the PL/SQL string literal and matching `sql.Named(...)` calls.
- Add shared Oracle bind-name validation for dynamic user bind names and REF CURSOR OUT parameter names.
- Validate all dynamic binds before any Oracle session side effect, including `DBMS_OUTPUT.ENABLE`.
- Add a cwd-independent Go AST sentinel that scans all production `oracle*.go` adapter files for unsafe literal and dynamic `sql.Named(...)` usage.
- Add a Makefile target `oracle-bind-audit` and route it through `perf-lsp` so strict markers are produced by the same rollup path as other v1.4 sentinels.
- Add focused unit coverage for reserved-name rejection, safe pass-through, DBMS_OUTPUT lockstep, REF CURSOR grammar, call-site migration, and backend error text.

Out of scope:
- PL/SQL `SELECT col INTO :var FROM tbl` parser work. It already shipped in `d8a4161` with `LSP12_2_PLSQL_SELECT_INTO_VAR_NOT_TABLE_REF`.
- Phase 18 performance backlog. The concrete leftovers are v1.5 backlog items, not Phase 22 debt.
- Rich-metadata X.3 stub adapters.
- Live Oracle or live PostgreSQL smoke. Phase 22 remains headless/unit coverage only.
- Lua-side pre-validation or prompt-time warnings for Oracle reserved bind names.
- Edits to the three locked helpers:
  - `lua/dbee/schema_filter_authority.lua`
  - `lua/dbee/schema_name_canonical.lua`
  - `lua/dbee/lsp/epoch_authority.lua`

</domain>

<decisions>
## Implementation Decisions

| ID | Decision | Evidence / Rationale |
| --- | --- | --- |
| ORA22-01 | Phase 22 is Oracle bind audit only. Drop former sub-item `(b)` and former sub-item `(c)`. | `(b)` already shipped in `d8a4161`. `(c)` maps to Phase 18 v1.5 backlog, not current debt. |
| ORA22-02 | Internal Oracle literal bind names must use the `p_` prefix. | Phase 16 learned `:schema` / `:table` can raise `ORA-01745`; current rich metadata uses `p_schema` / `p_table`. |
| ORA22-03 | Rename DBMS_OUTPUT `:line/:status` to `:p_line/:p_status` in lockstep with `sql.Named("p_line")` and `sql.Named("p_status")`. | `oracle_driver.go:358-360` currently has unprefixed internal literals in both SQL and Go args. |
| ORA22-04 | Do not auto-prefix user bind names. | Auto-prefixing would require rewriting user SQL and can collide with existing `:p_foo` placeholders. |
| ORA22-05 | Validate dynamic user bind names and reject unsafe names with a helpful error. | `oracle_driver.go:147` passes user-controlled names from `QueryExecuteOptions.Binds`; failing before Oracle parser gives a clearer recovery path. |
| ORA22-06 | Validate dynamic REF CURSOR OUT parameter names and reject unsafe names. | `oracle_refcursor.go:100` derives `param` from the SQL `:name /*CURSOR*/` marker; this cannot be rewritten safely. |
| ORA22-07 | Keep safe dynamic bind pass-through unchanged. | Existing queries using `:id`, `:name`, and typed values must keep working; only invalid/full-name unsafe names are rejected. |
| ORA22-08 | Use Oracle docs plus project-risk additions in the sentinel and runtime validator. | Oracle SQL Reserved Words Appendix E, PL/SQL Reserved Words and Keywords Appendix D, and `V$RESERVED_WORDS` establish the reserved/keyword source set; Phase 16 adds known parser-risk names. |
| ORA22-09 | Split marker ownership. | `ORACLE22_BIND_AUDIT_OK=true` belongs to `TestOracleBindAudit`; `PHASE22_ALL_PASS=true` belongs to a rollup test or Makefile-routed aggregate after all required Phase 22 tests pass. |
| ORA22-10 | The unsafe bind map is the full Phase 22 uppercase set, not the four-name seed list. | Plan-gate r1 found the four-name list left obvious ORA-01745 candidates such as `DATE`, `USER`, `LEVEL`, `GROUP`, `ORDER`, `ROWID`, `NUMBER`, `ROWNUM`, and `SYSDATE` unguarded. All keys must be uppercase ASCII, lookup uses `strings.ToUpper(name)`, and tests distinguish full-name equality from safe substrings such as `my_table`. |
| ORA22-11 | Validation must run before `DBMS_OUTPUT.ENABLE` and every `oracleNamedArgs` production call site must migrate to error-bearing form. | Current `executePLSQLLocked` and `executePLSQLWithCursor` enable DBMS_OUTPUT before constructing dynamic bind args; current call sites are `oracle_driver.go:252`, `oracle_driver.go:322`, and `oracle_refcursor.go:96`. |
| ORA22-12 | Source scanning must use `go/parser` / `go/ast`, resolve files cwd-independently, and assert properties rather than a closed literal set. | Regex scanning is whitespace/form fragile; exact-set matching would reject future safe `p_` internal binds; dynamic `sql.Named(IDENT, ...)` sites must be proven routed through validation. |
| ORA22-13 | Marker ownership is split and routed through Makefile target `oracle-bind-audit`, which `perf-lsp` invokes. | `ORACLE22_BIND_AUDIT_OK=true` belongs to the audit test; `PHASE22_ALL_PASS=true` belongs to a rollup test under `ORACLE22_ROLLUP=1`, not bare audit-only `go test`. |
| ORA22-14 | REF CURSOR marker grammar must match the validator grammar, and regexes introduced/touched by Phase 22 must be package-level compiled vars or manual ASCII scanners. | Lua bind scanning accepts `$` and `#`; current `cursorMarkerPattern` uses `\w+`, and `parseCursorParams` currently compiles its cleanup regex per call. |
| ORA22-15 | `validateOracleBindName` is not elevated to a fourth locked helper in v1.4; backend errors are the UX surface. | Oracle bind validation is single-package adapter logic covered by AST scan across production `oracle*.go` files. Lua-side pre-validation is out of scope; validation errors must bubble with the offending name and a `p_` rename hint. |
| ORA22-16 | Fix the existing REF CURSOR marker grammar bug in Phase 22. | Current `cursorMarkerPattern` uses Go regexp `\w+`, which excludes Oracle-legal `$` and `#` characters. Phase 22 must align cursor parsing with `validateOracleBindName` and add fuzz cases for `:A$B`, `:A#B`, `:cur_$1`, and `:p#bind`. |
| ORA22-17 | Commit to one load-bearing validation location for PL/SQL: inside the locked executors before `DBMS_OUTPUT.ENABLE`; REF CURSOR OUT args use a single validate-and-build range loop. | Validation must not be split between `QueryWithBinds` and `executePLSQLLocked`, because `executePLSQLLocked` owns `defer d.mu.Unlock()`. Pre-lock validation is allowed only as an opportunistic duplicate fast path. The REF CURSOR path uses Option A: validate `param` and append `sql.Named(param, ...)` in the same `RangeStmt` body before `DBMS_OUTPUT.ENABLE`, satisfying the AST whitelist without adding Pattern D. |
| ORA22-18 | Use helper-extraction for rollup markers, with an explicit test-to-helper mapping. | `TestPhase22Rollup` calls package-private helper functions on the same `*testing.T` and emits `PHASE22_ALL_PASS=true` only after `!t.Failed()`. It must not shell out, depend on sibling test ordering, or use subtests for marker gating. Focused top-level test names and helper ownership are fixed in `22-01-PLAN.md`. |
| ORA22-19 | Makefile integration uses single log ownership and DB18-style slice-grep verification. | `perf-lsp` `run_logged` owns appending to `UX13_ROLLUP_LOG`; `oracle-bind-audit` prints to stdout and is added to `.PHONY`. The perf-lsp hook slices `===CMD-SOURCE: oracle-bind-audit===` output and greps concrete RUN/PASS lines. |
| ORA22-20 | AST audit fails closed on unsupported `sql.Named` first-argument shapes and uses a whitelist for dynamic identifiers. | Literal and parenthesized forms are classified; unsupported `SelectorExpr`, `CallExpr`, `IndexExpr`, `TypeAssertExpr`, and similar computed names fail. Dynamic identifiers are only accepted through `oracleNamedArgs` or a RangeStmt/IfStmt validation whitelist. File discovery uses package-local `os.ReadDir(".")`, not `runtime.Caller`. |

### Per-Site Bind Matrix

| Site | Current name source | Static classification | Phase 22 policy |
| --- | --- | --- | --- |
| `oracle_refcursor.go:100` | Dynamic `param` from `:name /*CURSOR*/` | Unknown until runtime; caller can choose unsafe names | Validate name before DBMS_OUTPUT enable; reject unsafe/invalid names; no auto-prefix. |
| `oracle_driver.go:147` | Dynamic `name` from `binds` map | Unknown until runtime; user can choose unsafe names | Validate in `oracleNamedArgs`; reject unsafe/invalid names; no auto-prefix. |
| `oracle_driver.go:358-360` | Literal `line`, `status` | Project-risk DBMS_OUTPUT bind names; `STATUS` is Phase 16 parser-risk | Rename to `p_line`, `p_status` in SQL and args. |
| `oracle_driver.go:484` | Literal `p_schema`, `p_table` | Safe by `p_`; unprefixed `SCHEMA` / `TABLE` are unsafe | Preserve. |
| `oracle_driver.go:533` | Literal `p_schema`, `p_table` | Safe by `p_`; same unprefixed risk | Preserve. |
| `oracle_driver.go:573` | Literal `p_schema`, `p_table` | Safe by `p_`; same unprefixed risk | Preserve. |
| `oracle_driver.go:664` | Literal `p_schema`, `p_table` | Safe by `p_`; same unprefixed risk | Preserve. |
| `oracle_driver.go:765` | Literal `p_schema` | Safe by `p_`; unprefixed `SCHEMA` remains rejected for dynamic binds | Preserve. |

### Implementer Discretion

- Exact helper file name for the validation helper, as long as it remains in `dbee/adapters/oracle*.go` and is reused by user binds and REF CURSOR params.
- Exact Go AST implementation details, as long as it enumerates all production `sql.Named(...)` call expressions and fails on unsafe literal, unsupported computed, or unvalidated dynamic bind sites.
- Exact error type, as long as the returned error includes the offending bind name, an `oracle bind validation:` context prefix, and a `p_<name>` style rename hint.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before implementing.**

### Oracle Docs
- `https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/Oracle-SQL-Reserved-Words.html` - Appendix E, section `Oracle SQL Reserved Words`.
- `https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-RESERVED_WORDS.html` - Oracle Database Reference section `8.164 V$RESERVED_WORDS`; authoritative keyword view with `KEYWORD`, `RESERVED`, `RES_TYPE`, `RES_ATTR`, and `RES_SEMI` flags.
- `https://docs.oracle.com/cd/B28359_01/appdev.111/b28370/reservewords.htm` - Appendix D, `PL/SQL Reserved Words and Keywords`.

### Repo Evidence
- `dbee/adapters/oracle_driver.go:134-149` - user bind map conversion to `sql.Named(name, ...)`.
- `dbee/adapters/oracle_driver.go:216-322` - Oracle query/PLSQL execution paths that consume bind args.
- `dbee/adapters/oracle_driver.go:307-322` - PL/SQL DBMS_OUTPUT enable currently precedes bind arg construction.
- `dbee/adapters/oracle_driver.go:345-374` - DBMS_OUTPUT `GET_LINE` uses `:line/:status`.
- `dbee/adapters/oracle_driver.go:484,533,573,664,765` - existing rich metadata `p_schema` / `p_table` convention.
- `dbee/adapters/oracle_refcursor.go:19-42` - REF CURSOR marker parser currently uses narrower `\w+` grammar.
- `dbee/adapters/oracle_refcursor.go:84-100` - REF CURSOR DBMS_OUTPUT enable currently precedes bind arg construction.
- `dbee/adapters/oracle_driver_dbms_output_test.go:35-57` - DBMS_OUTPUT mock currently keys on `line` / `status`.
- `dbee/adapters/oracle_driver_context_test.go:146-235` - existing bind coercion and pass-through coverage.
- `dbee/adapters/oracle_refcursor_test.go:1-30` - existing cursor param parsing/filtering coverage.
- `lua/dbee/variables.lua:54-71` and `:639-642` - Oracle UI bind names come from SQL placeholders and are passed as backend named binds.
- `dbee/endpoints.go:70-131` - RPC query options preserve bind map keys as supplied.
- `dbee/adapters/oracle_plsql.go:121-141` - `formatOracleError` only rewrites `ORA-` / `PLS-` errors; validation errors bubble raw unless wrapped by Phase 22.
- `Makefile:37` - `.PHONY` target list that must include `oracle-bind-audit`.
- `Makefile:314-341` - `perf-lsp` has precedent for running focused Go guard targets before the broad `go-arch14` sweep.
- `.github/workflows/test.yml:12-34` - CI runs Go unit tests from `dbee`, so AST source scanning must not assume repo-root cwd.

### Dropped Scope Evidence
- `lua/dbee/lsp/context.lua:1360-1467` - PL/SQL block context and `SELECT INTO` guard already exist.
- `ci/headless/check_lsp12_2_symbols.lua:435-447` - `LSP12_2_PLSQL_SELECT_INTO_VAR_NOT_TABLE_REF` regression coverage already exists.
- `/Users/naveenkanuri/.claude/projects/-Users-naveenkanuri-Documents-nvim-dbee/memory/project_v14_phase18_shipped.md` - Phase 18 v1.5 backlog items are Mongo fixture refinement, nested-PG perf cohort, snapshot threading consolidation, and focused adapter test dedupe.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Existing `oracleNamedArgs` centralizes user bind conversion and is the right choke point for validation.
- Existing `parseCursorParams` / `executePLSQLWithCursor` centralize REF CURSOR OUT parameter names and must share the same identifier grammar as `validateOracleBindName`.
- Existing DBMS_OUTPUT tests can be extended to record SQL text, arg names, and whether `DBMS_OUTPUT.ENABLE` ran before a validation failure.

### Established Patterns
- Oracle internal metadata binds already use `p_schema` / `p_table`.
- Go adapter tests live in the `dbee/adapters` package and run under the existing CI `go test` sweep.
- Strict markers in this repo are collected via Makefile/headless rollup logs; Phase 22 must route markers through `oracle-bind-audit` rather than relying only on broad Go test adjacency.
- Package-level compiled regex vars already exist in Oracle code (`cursorMarkerPattern`, `plsqlCreatePattern`, `oracleErrorLocationPattern`).

### Integration Points
- `oracleNamedArgs` currently returns `[]any`; Phase 22 changes it to `([]any, error)` using `map[string]struct{}` unsafe-set semantics and updates all production call sites:
  - `dbee/adapters/oracle_driver.go:252`
  - `dbee/adapters/oracle_driver.go:322`
  - `dbee/adapters/oracle_refcursor.go:96`
- Dynamic validation must happen inside the locked executors before driver execution and before session-side DBMS_OUTPUT enable. Optional duplicate pre-lock validation may reject cheap failures earlier, but it is not the load-bearing location.
- REF CURSOR validation must happen immediately after `parseCursorParams`, before `DBMS_OUTPUT.ENABLE`, and must fix today's `$` / `#` cursor-marker parse bug.
- The AST sentinel must scan production files only: `oracle.go`, `oracle_driver.go`, `oracle_plsql.go`, `oracle_refcursor.go`, and `oracle_wallet.go` today, plus future `oracle*.go` files excluding `_test.go`.

</code_context>

<specifics>
## Specific Ideas

Recommended validation error shape:

```text
oracle bind validation: oracle bind name "table" is reserved or unsafe; rename the SQL placeholder and bind option to a non-reserved name such as "p_table"
```

Recommended focused commands for execution phase:

```bash
make oracle-bind-audit
env GOCACHE=/tmp/codex-go-cache go -C dbee test ./adapters
```

</specifics>

<deferred>
## Deferred Ideas

- Lua-side mirror validation for Oracle bind names before the user prompt completes.
- Project memory v1.5 backlog row for Lua-side pre-validation: backend bind validation errors currently surface through the editor execute callback / `vim.notify(WARN)` path after the prompt completes.
- Live Oracle `V$RESERVED_WORDS` smoke query that records the current database's flags for representative unsafe words; this belongs with Phase 20/live-DB smoke, not this headless plan.
- Phase 18 v1.5 backlog:
  - Mongo fixture refinement.
  - nested-PG perf cohort.
  - 5-site snapshot threading consolidation.
  - focused adapter test 2x run dedupe.
- Rich-metadata X.3 stub adapters.

</deferred>

---

*Phase: 22-oracle-correctness*
*Context revised: 2026-05-07*
