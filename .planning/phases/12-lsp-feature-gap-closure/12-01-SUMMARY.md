---
phase: 12-lsp-feature-gap-closure
plan: 01
subphase: "12.1"
subsystem: lsp-hover-resolve
tags: [lsp, hover, resolve, completion, cache, perf]
requirements-completed: [DBEE-FEAT-02]
duration: 1 session
completed: 2026-05-01
---

# Phase 12.1 Summary: LSP Hover + Completion Resolve

Phase 12.1 is implemented in the working tree: cache-backed `textDocument/hover`, cache-truthful `completionItem/resolve`, strict LSP12 sentinels, perf probes, and user-facing feature flag docs.

## Accomplishments

- Added `lsp.hover` and `lsp.resolve` config flags, advertised `hoverProvider` and `completionProvider.resolveProvider` behind those flags, and registered request handlers in the in-process LSP server.
- Added cache-only hover support for schemas, tables, columns, nil-on-keyword/unknown behavior, quote-aware canonical lookup, bounded statement scanning, and single-table SELECT-list column hover.
- Added dbee-only completion resolve with exact cache-origin identity, generation/root-epoch staleness checks, authority fail-closed behavior, prior-doc scrubbing, and required per-generation memoization.
- Added compact dbee `CompletionItem.data` only for unambiguous schema/table/scoped-column items; ambiguous global column fallback items intentionally pass through unresolved.
- Added shared object documentation rendering with markdown escaping and completion-specific plaintext fallback.
- Extended the LSP perf harness with 8 isolated LSP12 scenarios while preserving `LSP01_SCENARIOS_COUNT=33`.
- Added strict LSP12 functional and rollup gates, wired into `make perf-lsp` and UX13 aggregation.

## Key Files

Created:

- `lua/dbee/lsp/object_docs.lua`
- `lua/dbee/lsp/hover.lua`
- `lua/dbee/lsp/resolve.lua`
- `ci/headless/check_lsp12_hover_resolve.lua`
- `ci/headless/check_lsp12_rollup.lua`

Modified:

- `lua/dbee/config.lua`
- `lua/dbee/lsp/server.lua`
- `lua/dbee/lsp/init.lua`
- `lua/dbee/lsp/context.lua`
- `lua/dbee/lsp/schema_cache.lua`
- `ci/headless/check_lsp_perf.lua`
- `ci/headless/check_ux13_rollup.lua`
- `Makefile`
- `README.md`
- `doc/dbee.txt`

## Task Commits

Commits could not be created in this sandbox because git refused to create `.git/index.lock` with `Operation not permitted`. The implementation remains uncommitted in the working tree for a normal git environment to commit.

Suggested commit split:

1. `feat(12.1 task1-8): add lsp hover and resolve`
2. `test(12.1 task9-11): add lsp12 hover resolve gates`
3. `docs(12.1 task12): document hover resolve flags`

## Verification

Final requested gates passed on 2026-05-01:

```text
make perf-lsp PERF_PLATFORM=macos
LSP12_PERF_SCENARIOS_COUNT=8
LSP12_HOVER_P95_MS=0.53
LSP12_RESOLVE_P95_MS=0.19
LSP12_HOVER_PERF_BUDGET_50MS=true
LSP12_RESOLVE_PERF_BUDGET_100MS=true
LSP12_ROLLUP_MARKERS_CHECKED=33
LSP12_HOVER_RESOLVE_ALL_PASS=true
UX13_ROLLUP_MARKERS_CHECKED=91
UX13_ALL_PASS=true
ARCH14_ROLLUP_MARKERS_CHECKED=96
ARCH14_ALL_PASS=true
```

```text
go -C dbee test ./core ./handler ./adapters
ok  	github.com/kndndrj/nvim-dbee/dbee/core	32.594s
ok  	github.com/kndndrj/nvim-dbee/dbee/handler	1.036s
ok  	github.com/kndndrj/nvim-dbee/dbee/adapters	2.183s
```

Additional targeted gates passed:

```text
ci/headless/check_lsp12_hover_resolve.lua
LSP12_HOVER_TABLE_OK=true
LSP12_HOVER_COLUMN_OK=true
LSP12_HOVER_SCHEMA_OK=true
LSP12_HOVER_NO_SYNC_DB=true
LSP12_HOVER_NO_ASYNC_DB=true
LSP12_RESOLVE_SCHEMA_DOCS_OK=true
LSP12_RESOLVE_TABLE_DOCS_OK=true
LSP12_RESOLVE_COLUMN_DOCS_OK=true
LSP12_RESOLVE_GENERATION_PROOF_ALL_PATHS=true
LSP12_RESOLVE_NO_SYNC_DB=true
LSP12_RESOLVE_NO_ASYNC_DB=true
```

Preserved smoke markers from `make perf-lsp` include:

```text
DRAW01_ALL_PASS=true
STRUCT01_ALL_PASS=true
NOTES01_ALL_PASS=true
DCFG01_DRAWER_LIFECYCLE_ALL_PASS=true
DCFG01_COORDINATION_ALL_PASS=true
DCFG02_WIZARD_ALL_PASS=true
DCFG02_FILESOURCE_ALL_PASS=true
```

## Deviations

- Atomic commits were not possible in this sandbox due `.git/index.lock` permission denial. No files were reverted or pushed.
- During final diff review, resolve formatting was tightened so `completionItem/resolve` honors `completionItem.documentationFormat` rather than hover formatting capabilities. The LSP12 markdown-format sentinel now asserts the plaintext resolve fallback directly.
- The new cached-column metadata matcher was also tightened to use helper equivalence for case-insensitive adapters, preserving the Phase 11 r6 canonical contract for quoted SQLite-style identifiers.

## Self-Check: PASSED

The implementation stays within Phase 12.1 scope: hover and completion resolve only. Code actions and symbols remain later Phase 12 work. Phase 14 `schema_filter_authority.lua` and Phase 11 r6 `schema_name_canonical.lua` were not modified.
