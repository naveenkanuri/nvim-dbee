---
phase: 12-lsp-feature-gap-closure
plan: 02
subphase: "12.2"
subsystem: lsp-symbols
tags: [lsp, document-symbol, workspace-symbol, cache, perf]
requirements-completed: [DBEE-FEAT-02]
duration: 1 session
completed: 2026-05-01
---

# Phase 12.2 Summary: LSP Document And Workspace Symbols

Phase 12.2 is implemented in the working tree: `textDocument/documentSymbol`,
`workspace/symbol`, strict LSP12_2 sentinels, perf cohorts, rollup wiring, and
user-facing feature flag docs.

## Accomplishments

- Added `lsp.document_symbols` and `lsp.workspace_symbols` config flags and
  advertised the corresponding LSP capabilities only when enabled.
- Added source-text document symbols with hierarchical `Schema -> Table ->
  Column` output for hierarchical clients and `SymbolInformation` fallback for
  flat clients.
- Added bounded whole-document SQL reference extraction with 10,000-line / 1
  MiB caps, source ranges, unqualified/unknown root-level fallback, and
  document parse-cache eviction on change, close, and invalid buffer access.
- Added cache-only workspace symbols for active-connection schemas/tables with
  `epoch_authority`, schema-filter authority, canonical substring matching,
  deterministic cap-before-copy behavior, and percent-encoded `dbee://` URIs.
- Added authority-aware document-symbol enrichment: source symbols always emit,
  while schema hierarchy is added only when live authority is `ok`, the cache is
  epoch-fresh, and the schema is in scope.
- Routed diagnostics through the same token-aware table-reference extraction as
  document symbols so strings/comments cannot create false schema-aware
  diagnostics.
- Added `ci/headless/check_lsp12_2_symbols.lua`, extended the LSP12 rollup with
  exact-once Phase 12.2 markers, wired `make perf-lsp`, and added five
  Phase 12.2 perf cohorts without changing Phase 12.1 scenario counts.
- Updated README and Vim help for the new flags and high-level symbol behavior.

## Key Files

Created:

- `lua/dbee/lsp/symbols.lua`
- `ci/headless/check_lsp12_2_symbols.lua`

Modified:

- `lua/dbee/config.lua`
- `lua/dbee/lsp/context.lua`
- `lua/dbee/lsp/schema_cache.lua`
- `lua/dbee/lsp/server.lua`
- `ci/headless/check_lsp12_rollup.lua`
- `ci/headless/check_lsp_perf.lua`
- `Makefile`
- `README.md`
- `doc/dbee.txt`
- `.planning/phases/12-lsp-feature-gap-closure/12-02-PLAN.md`
- `.planning/STATE.md`

## Task Commits And Fix Commits

The main implementation and r1-r3 impl-fix commits are present in git history
through `abfabac`. During the r4 fix pass, this sandbox refused writes under
`.git/` with `Operation not permitted`, so the r4 changes are present in the
working tree but could not be committed here.

R4 commit split to create in a writable git environment:

1. `fix(12.2): gate document symbol enrichment by authority`
2. `fix(12.2): use token refs for diagnostics`
3. `docs(12.2): reconcile r4 marker ledger`

## Verification

Final requested gates passed on 2026-05-01:

```text
make perf-lsp PERF_PLATFORM=macos
LSP12_PERF_SCENARIOS_COUNT=10
LSP12_HOVER_P95_MS=0.53
LSP12_RESOLVE_P95_MS=0.21
LSP12_HOVER_PERF_BUDGET_50MS=true
LSP12_RESOLVE_PERF_BUDGET_100MS=true
LSP12_2_PERF_SCENARIOS_COUNT=5
LSP12_2_DOCSYMBOL_P95_MS=36.96
LSP12_2_WORKSPACESYMBOL_P95_MS=3.31
LSP12_2_DOCSYMBOL_PERF_BUDGET_50MS=true
LSP12_2_WORKSPACESYMBOL_PERF_BUDGET_100MS=true
LSP12_ROLLUP_MARKERS_CHECKED=58
LSP12_HOVER_RESOLVE_ALL_PASS=true
LSP12_2_ROLLUP_MARKERS_CHECKED=52
LSP12_2_ALL_PASS=true
UX13_ROLLUP_MARKERS_CHECKED=91
UX13_ALL_PASS=true
ARCH14_ROLLUP_MARKERS_CHECKED=96
ARCH14_ALL_PASS=true
```

```text
go -C dbee test ./core ./handler ./adapters
ok  	github.com/kndndrj/nvim-dbee/dbee/core
ok  	github.com/kndndrj/nvim-dbee/dbee/handler
ok  	github.com/kndndrj/nvim-dbee/dbee/adapters
```

Targeted functional sentinel also passed:

```text
ci/headless/check_lsp12_2_symbols.lua
LSP12_2_DOCSYMBOL_HIERARCHY_OK=true
LSP12_2_DOCSYMBOL_FLAT_FALLBACK_OK=true
LSP12_2_DOCSYMBOL_AUTHORITY_DEGRADES_TO_NAME=true
LSP12_2_DIAGNOSTICS_IGNORES_COMMENTS_AND_STRINGS=true
LSP12_2_DOCSYMBOL_LARGE_BUFFER_BOUNDED=true
LSP12_2_WORKSPACESYMBOL_AUTHORITY_FAIL_CLOSED=true
LSP12_2_WORKSPACESYMBOL_AUTHORITY_OK_SCOPED=true
LSP12_2_WORKSPACESYMBOL_EPOCH_FAIL_CLOSED=true
LSP12_2_NEW_SYMBOL_CODE_NO_HELPER_BYPASS=true
LSP12_2_ROLLUP_EXACTLY_ONCE_OK=true
```

## Deviations

- R4 atomic commits were not possible in this sandbox due `.git/index.lock`
  permission denial. No files were reverted or pushed.
- `lua/dbee/lsp/init.lua` did not need a direct edit; capability advertisement
  is owned by `lua/dbee/lsp/server.lua`, which is what `init.lua` launches.
- The final document-symbol parser uses a table-reference line prefilter for
  whole-document symbols so large SQL buffers stay bounded while still emitting
  references before line 200 and near the 10,000-line cap.

## Self-Check: PASSED

The implementation stays within Phase 12.2 scope: document/workspace symbols
only. Phase 12.3 code actions remain unimplemented. Phase 14
`schema_filter_authority.lua`, Phase 11 r6 `schema_name_canonical.lua`, and
Phase 12.1 `epoch_authority.lua` were not modified.
