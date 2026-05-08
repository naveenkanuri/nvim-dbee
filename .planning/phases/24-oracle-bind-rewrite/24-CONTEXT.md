# Phase 24: Oracle Bind Transparent Rewriter - Context

**Gathered:** 2026-05-08
**Status:** Ready for planning r2 after r1 narrow fold
**Source:** User-supplied combined discuss/research/plan prompt, Phase 22/22.5 shipped code, Phase 22/23 plan structure, local code audit, Oracle/go-ora documentation check

<phase_overview>
## Goal

Phase 24 makes Oracle-legal user bind names containing `$` or `#` run successfully through the current go-ora adapter. The adapter accepts user-surface bind identifiers using Oracle's nonquoted identifier character set, rewrites only the driver-facing SQL placeholders and `sql.Named` keys into go-ora-compatible identifiers, and reverse-maps driver errors back to the original user names.

## Surface

In scope:
- User SQL passed to `oracleDriver.QueryWithBinds`.
- User bind map keys passed through `oracleNamedArgs`.
- PL/SQL execution in `executePLSQLLocked`.
- REF CURSOR marker parsing and OUT arg construction in `oracle_refcursor.go`.
- Existing Phase 22 audit and unit tests that encode validator behavior.
- New tokenizer/rewriter unit tests.

Non-goals:
- Live Oracle smoke tests or testcontainers Oracle.
- Lua-side prompt validation.
- Generic SQL parser dependency or new external Go dependency.
- Rewriting internal static metadata binds such as `:p_schema`, `:p_table`, `:p_line`, or `:p_status`.
- Editing Lua locked helpers or non-Oracle adapters.

</phase_overview>

<decisions>
## Implementation Decisions

All decisions are **status: locked at r1** after the narrow fold.

| ID | Status | Decision | Evidence / Rationale |
| --- | --- | --- | --- |
| ORA24-01 | locked at r1 | Rewrite scheme is percent-encoding-style: `$ -> _x24_`, `# -> _x23_`. The mapping is reversible by scanning rewritten names for those substrings. User names containing `_x24_` or `_x23_` in any case are rejected before rewrite. | Avoids adding non-word characters to driver identifiers and avoids reverse-map ambiguity. go-ora compares bind names case-insensitively, so sentinel checks must case-fold. |
| ORA24-02 | locked at r1 | Implement a small Oracle SQL tokenizer/scanner. It must skip single-quoted strings with `''`, q-quoted strings using the full ORA24-17 delimiter rule, double-quoted identifiers, line comments, and block comments. | Regex-only SQL rewriting would rewrite bind-looking text inside literals/comments. Oracle SQL docs define the q-quote alternate literal mechanism. |
| ORA24-03 | locked at r1 | In code regions only, detect bind references using `:([A-Za-z_][A-Za-z0-9_$#]*)`. Leading `$` and `#` are invalid and must fail user validation. | Phase 24 accepts Oracle-style `$` / `#` in the identifier body, not as the first character. Underscore-first remains allowed for compatibility with existing validator behavior. |
| ORA24-04 | locked at r1 | Apply rewriting at the Oracle adapter boundary before go-ora sees SQL or named args. Plain SQL uses rewritten text before `conn.ExecContext` / `d.c.QueryOnConn`; PL/SQL uses rewritten text before `conn.ExecContext`; user bind map keys are transformed before `sql.Named`. Driver-name collision detection is case-insensitive across SQL refs, bind-map keys, and cursor params. | Current plain SQL path passes `query` and `bindArgs` at `oracle_driver.go:474-509`; PL/SQL path passes `plsqlQuery` at `oracle_driver.go:540-560`; go-ora matches parameter names case-insensitively. |
| ORA24-05 | locked at r1 | Split validation into explicit surfaces and delete legacy `validateOracleBindName`. `validateOracleBindNameUser(name)` allows `[A-Za-z_][A-Za-z0-9_$#]*` but rejects reserved/unsafe names and case-insensitive sentinel substrings; `validateOracleBindNameDriver(name)` keeps strict go-ora-compatible `[A-Za-z_][A-Za-z0-9_]*` and reserved/unsafe protection. | Current `validateOracleBindName` at `oracle_driver.go:310-318` combines user and driver concerns and rejects `$` / `#`; keeping it would allow ambiguous call-site drift. |
| ORA24-06 | locked at r1 | Reverse-map go-ora errors mentioning rewritten names back to original names only for colon-prefixed bind occurrences. Reverse mapping happens after `formatOracleError`, and wrappers preserve `Unwrap()` to the original driver error. | Naive substring replacement can corrupt incidental user/NLS text. Phase 22 formatting currently rebuilds error strings without preserving wrappers. |
| ORA24-07 | locked at r1 | Cursor marker detection, broad validation, parse, and cleanup must use the same code-region scanner as the rewriter. Strict and broad cursor regexes may still apply, but only inside code regions. | Current `cursorMarkerPattern` and `cursorMarkerBroadPattern` scan raw SQL. Phase 24 cannot leave cursor markers on a different lexical authority from bind rewriting. |
| ORA24-08 | locked at r1 | DBMS_OUTPUT internal binds `:p_line` and `:p_status` are static internal names and do not need rewrite. Audit must assert they remain unchanged. | Phase 22 lockstep is covered by `oracle_driver_dbms_output_test.go`; `fetchDBMSOutputFromConn` uses `:p_line` / `:p_status` in `oracle_driver.go:574-576`. |
| ORA24-09 | locked at r1 | Preserve Phase 22 hotfix behavior that `:= /*CURSOR*/` and stray `/*CURSOR*/` comments are not treated as cursor markers. | Current broad regex excludes `=` at `oracle_refcursor.go:22-28`; `oracle_refcursor_test.go` has stray cursor comment coverage. |
| ORA24-10 | locked at r1 | Emit 13 ORA24 strict markers, one `PHASE24_ALL_PASS=true` rollup, and diagnostics: `ORA24_REWRITE_MS`, `ORA24_TOKENIZER_CASES_DIAGNOSTIC`, and `ORA24_SENTINEL_CORPUS_DIAGNOSTIC`. | Marker table in `PLAN.md` defines ownership and success criteria. |
| ORA24-11 | locked at r1 | Extend `oracle_bind_audit_test.go` so all dynamic `sql.Named` sites are proven to pass through explicit user/driver validation and/or the new rewrite helper. The audit must fail closed on unsupported computed first args and any reintroduction of `validateOracleBindName`. | Current AST audit recognizes `validateOracleBindName` dominance at `oracle_bind_audit_test.go:357-470`; that must become two-surface aware. |
| ORA24-12 | locked at r1 | No live Oracle DB is required. Use existing mock drivers plus tokenizer/rewriter unit tests. | Existing Phase 22 tests use mock drivers and source scanning; the new behavior can be verified before go-ora by inspecting rewritten SQL/args and wrapped errors. |
| ORA24-13 | locked at r1 | Implementation scope is eight files: the six base files plus `oracle_driver_context_test.go` and `oracle_refcursor_test.go`. | Local audit found existing tests at `oracle_driver_context_test.go:213-218` and `oracle_refcursor_test.go:94-99` that must change from reject to accept/rewrite. |
| ORA24-14 | locked at r1 | The three locked helpers remain untouched. | Same locked helper contract as Phases 22 and 23. |
| ORA24-15 | locked at r1 | Preserve Phase 22 and 22.5 contracts with exact validator error text: reserved names reject, `p_` internal binds remain safe, `oracleSafeBindSuggestion` remains valid against the new user validator and driver validator as applicable, and Phase 22 rollup helpers still pass under updated semantics. | Phase 22/22.5 shipped commits `e8b1b6d`, `31cd153`, and `988341f`; r1 locks message text to prevent drift. |
| ORA24-16 | locked at r1 | Sentinel-collision UX is locked: `oracle bind name %q contains internal sentinel '_x24_' or '_x23_' (case-insensitive); rename to avoid collision`. | Reversible encoding depends on rejecting literal `_x24_` and `_x23_` substrings under case folding. |
| ORA24-17 | locked at r1 | Q-quote delimiter rule is complete: after `q'` or `Q'`, opener `X` is any ASCII character that is not whitespace and not `'`; if `X` is one of `(`, `{`, `[`, `<`, terminator is the matched closer `)`, `}`, `]`, `>` followed by `'`; otherwise terminator is `X'`. Whitespace opener and single-quote opener reject as tokenizer errors. | CRIT-1 found the r0 wording under-specified and likely to cause silent SQL corruption. |
| ORA24-18 | locked at r1 | Delete `validateOracleBindName`. All call sites must explicitly choose `validateOracleBindNameUser` or `validateOracleBindNameDriver`; audit fails on the legacy function name token. | A compatibility wrapper would preserve the exact ambiguity Phase 24 is removing. |
| ORA24-19 | locked at r1 | Reverse-error mapping is boundary-aware: only `:driver_name` bind occurrences are replaced with `:original_name`, with non-identifier boundaries around the colon-prefixed token. Incidental bare substrings are never replaced. | Prevents mangling user data or localized message text containing rewritten-name substrings. |
| ORA24-20 | locked at r1 | Rewrite performance budgets are strict: small cohort (~1KB, 0-2 binds) P95 <= 5 microseconds; medium (~10KB, 10 binds) P95 <= 50 microseconds; large (~100KB or 50+ binds) P95 <= 1 millisecond. Fast path for unchanged SQL and unchanged bind map is zero-alloc. | Rewriting runs on every Oracle execution and must not become visible latency or allocation churn. |
| ORA24-21 | locked at r1 | No regexp is allowed in the per-query rewrite path. The tokenizer and bind detector use manual byte scanning / ASCII helpers. Regex remains allowed in tests and non-hot audit helpers only. | Prevents repeated regexp allocation/search costs and keeps scanner behavior explicit. |
| ORA24-22 | locked at r1 | Case-folding contract: sentinel detection and driver-name collision detection use uppercase-folded names; rewrite preserves user-supplied case verbatim for emitted driver names; `filterCursorBindNames` continues comparing original user names case-insensitively; reverse-error map keys are case-sensitive driver names generated by the adapter. | Aligns with go-ora case-insensitive parameter matching while preserving user-visible names and Phase 22 cursor filtering behavior. |
| ORA24-23 | locked at r1 | Rewrite/tokenizer work must happen before `d.mu.Lock()`. The mutex protects session connection acquisition and driver execution only, not CPU-bound SQL scanning. | Current `QueryWithBinds` locks before bind processing; doing the new scan under lock would serialize unrelated Oracle executions. |

### Locked Validator Error Text

User grammar failure:

```text
invalid oracle bind identifier %q (grammar requires letter or underscore start, then [A-Za-z0-9_$#]*); rename to %q
```

User reserved/unsafe failure:

```text
oracle bind name %q is reserved or unsafe; rename the SQL placeholder and bind option to a non-reserved name such as %q
```

Sentinel collision:

```text
oracle bind name %q contains internal sentinel '_x24_' or '_x23_' (case-insensitive); rename to avoid collision
```

Driver grammar failure is internal-only and should be treated as an invariant violation after rewrite, not as a normal user-facing validator error.

### Suggestion Semantics

`oracleSafeBindSuggestion` remains the rename hint helper, but Phase 24 changes the reason `$` / `#` appear in the corpus: user-surface validation no longer rejects `$` / `#` in identifier bodies, so suggestions do not strip `$` / `#` merely because those characters are present. For grammar failures such as `1abc`, the suggestion is `p_1abc`. Tests must assert suggestions validate under the intended surface.

### Adapter Boundary Matrix

| Site | Current Behavior | Phase 24 Behavior |
| --- | --- | --- |
| `oracleNamedArgs` | Validates with go-ora grammar and calls `sql.Named(name, ...)`. | Validate user name, rewrite to driver name, validate driver name, call `sql.Named(driverName, ...)`, and return driver-to-user mapping metadata. |
| Plain `QueryWithBinds` query path | Calls `d.c.QueryOnConn(query, bindArgs...)`. | Calls `d.c.QueryOnConn(rewrittenSQL, rewrittenArgs...)`; reverse-map any error. |
| Plain exec path | Calls `conn.ExecContext(query, bindArgs...)`. | Calls `conn.ExecContext(rewrittenSQL, rewrittenArgs...)`; reverse-map any error. |
| PL/SQL path | Validates args, enables DBMS_OUTPUT, executes `plsqlQuery`. | Builds rewrite plan before DBMS_OUTPUT enable, validates/rewrite args, executes rewritten `plsqlQuery`, and reverse-maps errors. |
| REF CURSOR path | Parses strict cursor params, validates with go-ora grammar, passes `sql.Named(param, sql.Out{...})`. | Parses original cursor params with Oracle user grammar, rewrites cursor param names for driver OUT args, executes rewritten clean query, and keeps original cursor names for result labeling/error text. |

</decisions>

<canonical_refs>
## Canonical References

Downstream agents MUST read these before implementing.

### External

- `https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/Database-Object-Names-and-Qualifiers.html` - Oracle nonquoted identifier character rules, including `_`, `$`, and `#`, plus reserved-word restrictions.
- `https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/Literals.html` - Oracle ordinary string literal and q-quote alternate literal behavior.
- `https://github.com/sijms/go-ora` - go-ora named-parameter usage; SQL placeholders are matched to `sql.Named("name", value)`.
- `/Users/naveenkanuri/go/pkg/mod/github.com/sijms/go-ora/v2@v2.9.0/utils.go:59-138` - go-ora `refineSqlText` and `:(\w+)` parameter parser behavior; dependency compatibility risk for q-quotes.
- `/Users/naveenkanuri/go/pkg/mod/github.com/sijms/go-ora/v2@v2.9.0/command.go:1768-1812` - go-ora case-insensitive matching of parsed names to driver parameters.

### Phase 22 / 22.5 Planning

- `.planning/phases/22-oracle-correctness/PLAN.md` - Phase 22 locked contracts, strict marker ownership, and helper fence.
- `.planning/phases/22-oracle-correctness/22-CONTEXT.md` - Phase 22 decisions ORA22-01 through ORA22-20 and unsafe bind set rationale.
- `.planning/phases/22-oracle-correctness/22-01-PLAN.md` - Existing audit plan and unsafe bind matrix.

### Current Code

- `dbee/adapters/oracle_driver.go:310-318` - current single-surface validator rejects `$` / `#`.
- `dbee/adapters/oracle_driver.go:320-345` - `oracleSafeBindSuggestion` strips `$` / `#` and must remain driver-valid.
- `dbee/adapters/oracle_driver.go:348-371` - current `oracleNamedArgs` choke point for user bind map keys.
- `dbee/adapters/oracle_driver.go:467-509` - plain SQL path and driver execution boundary.
- `dbee/adapters/oracle_driver.go:526-560` - PL/SQL execution path and DBMS_OUTPUT side-effect ordering.
- `dbee/adapters/oracle_refcursor.go:19-30` - current cursor marker regexes and cleanup regex.
- `dbee/adapters/oracle_refcursor.go:105-131` - cursor param validation and OUT arg construction.
- `dbee/adapters/oracle_plsql.go:119-150` - Oracle error formatting that must compose with reverse error mapping.
- `dbee/adapters/oracle_bind_audit_test.go:52-107` - Phase 22 audit core and marker emission.
- `dbee/adapters/oracle_bind_audit_test.go:230-263` - Phase 22.5 suggestion-validity sentinel.
- `dbee/adapters/oracle_bind_audit_test.go:323-470` - AST audit dominance logic that must become user/driver-surface aware.
- `dbee/adapters/oracle_driver_context_test.go:192-228` - unsafe bind matrix currently rejects `$` / `#`.
- `dbee/adapters/oracle_refcursor_test.go:84-102` - cursor marker tests currently reject `$` / `#`.
- `dbee/adapters/oracle_driver_dbms_output_test.go` - DBMS_OUTPUT `p_line` / `p_status` preservation.

</canonical_refs>

<scope_fence>
## Files Allowed To Write During Execution

- `dbee/adapters/oracle_driver.go`
- `dbee/adapters/oracle_bind_rewrite.go` (new)
- `dbee/adapters/oracle_refcursor.go`
- `dbee/adapters/oracle_plsql.go`
- `dbee/adapters/oracle_bind_audit_test.go`
- `dbee/adapters/oracle_bind_rewrite_test.go` (new)
- `dbee/adapters/oracle_driver_context_test.go`
- `dbee/adapters/oracle_refcursor_test.go`

Do not modify:

- `lua/dbee/schema_filter_authority.lua`
- `lua/dbee/schema_name_canonical.lua`
- `lua/dbee/lsp/epoch_authority.lua`
- non-Oracle adapters
- Lua UI/LSP files
- `Makefile` unless plan-gate r1 explicitly requests a Phase 24 make target

</scope_fence>

<deferred>
## Deferred / Out Of Scope

- Live Oracle validation that go-ora accepts the rewritten names against a real database.
- Lua-side Oracle bind pre-validation or editor diagnostics.
- General Oracle SQL parser dependency.
- Supporting quoted bind variable names. Phase 24 only handles nonquoted bind identifiers.
- Alternate rewrite schemes that preserve `$` / `#` through driver extension.
- Makefile integration for a standalone `oracle-bind-rewrite` target; use direct Go test commands in r0 unless plan-gate asks otherwise.

</deferred>

---

*Phase: 24-oracle-bind-rewrite*
*Context gathered: 2026-05-08*
