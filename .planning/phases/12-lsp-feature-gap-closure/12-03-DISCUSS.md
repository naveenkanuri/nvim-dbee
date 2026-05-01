# Phase 12.3: LSP Code Actions - Discussion

**Gathered:** 2026-05-01
**Status:** Ready for research and planning
**Codex thread:** `019de2ac-edf7-76a1-ba1a-c3f738a2dd10`
**Base HEAD:** `692f64a`

## Phase Boundary

Phase 12.3 ships the code-action portion of DBEE-FEAT-02:

- `textDocument/codeAction` for cache-backed SQL edits.
- `workspace/executeCommand` support for the server-owned refresh/reload commands returned by code actions.
- No SQL formatter, JOIN generator, semantic tokens, inlay hints, multi-client connection architecture, or custom Neovim picker.

The MVP actions are:

- `Expand SELECT * -> list columns`
- `Qualify identifier: users -> public.users`
- `Refresh schema cache`
- `Reload table metadata`

## Carry-Forward Constraints

- Inherit D-306..D-337 from `.planning/DISCUSS-phase12.md`.
- Inherit D-338..D-395 from Phase 12.1 and D-396..D-450 from Phase 12.2.
- Keep `schema_filter_authority`, `schema_name_canonical`, and `epoch_authority` as the only authority/canonical/epoch sources of truth.
- Do not modify the three helper modules unless a later gate explicitly asks for helper work.
- Keep all LSP request paths cache-only and bounded.
- Preserve Phase 12.1/12.2 smoke and rollup behavior.

## Locked Decisions

### Protocol Surface

- **D-451:** Phase 12.3 ships only standard LSP code actions plus `workspace/executeCommand` for server-owned commands. The refresh/reload actions cannot be command-only without execute-command support.
- **D-452:** Advertise `codeActionProvider` only when Phase 12.3 code actions are enabled.
- **D-453:** Advertise `executeCommandProvider.commands` as the exact enabled command-action subset. If both command actions are disabled, omit `executeCommandProvider` while keeping edit code actions available.
- **D-454:** Do not add `codeAction/resolve` in Phase 12.3. Edit actions are cheap enough to construct during discovery; command actions carry all arguments needed by `workspace/executeCommand`.
- **D-455:** `textDocument/codeAction` returns a stable ordered array of `CodeAction` literals. It does not return client-side command literals that Neovim must implement locally.

### Config

- **D-456:** Add `lsp.code_actions = true` as the master rollback flag.
- **D-457:** Add flat per-action toggles to match the existing `lsp.hover`, `lsp.resolve`, `lsp.document_symbols`, and `lsp.workspace_symbols` style: `lsp.code_action_expand_select_star`, `lsp.code_action_qualify_identifier`, `lsp.code_action_refresh_schema`, and `lsp.code_action_reload_table_metadata`, all default `true`.
- **D-458:** Add `lsp.code_action_max_expand_columns = 200`. `Expand SELECT *` is omitted for wider tables rather than emitting a truncated, semantically misleading column list.

### Discovery And Ordering

- **D-459:** Implement a new `lua/dbee/lsp/code_actions.lua` registry. The server asks each registered action to contribute zero or one action for the request.
- **D-460:** Stable picker order is: expand star, qualify identifier, reload table metadata, refresh schema cache.
- **D-461:** `context.only` is honored. Source actions are omitted for refactor-only requests, and refactor actions are omitted for source-only requests.
- **D-462:** `Refresh schema cache` is range-independent in normal code-action requests, but still obeys the master code-action enabled flag and authority/epoch fail-closed gates. `LSP12_3_NO_ACTIONABLE_RANGE_EMPTY` is scoped to refactor-only requests outside an actionable range.

### Expand SELECT *

- **D-463:** Expand action applies only when the request range/cursor is on an unqualified `*` token in a top-level select list before that statement's `FROM`. Qualified wildcards such as `u.*` and `schema.table.*` return no action in v1.3.
- **D-464:** v1.3 supports single-table statements only. More than one table reference, JOIN, comma FROM list, CTE ambiguity, or missing table metadata returns no action.
- **D-465:** Columns come from already-cached metadata through helper-routed cache APIs. Missing, unloaded, stale, filtered, or authority-unavailable metadata returns no action.
- **D-466:** The WorkspaceEdit uses versioned `documentChanges` and contains exactly one text edit in the current document replacing the `*` token.
- **D-467:** Generated column identifiers preserve quote intent. If the table reference uses quoted schema/table syntax, generated columns are quoted. Otherwise exact cached names are emitted unquoted only when `schema_name_canonical.is_unquoted_canonical` says that is safe for the adapter fold.

### Qualify Identifier

- **D-468:** Qualify action applies only when the request range/cursor is on an unqualified table identifier from the active statement's table-reference context.
- **D-469:** Already-qualified identifiers, aliases, column identifiers, keywords, CTE/local relation shadows, and ambiguous global table matches return no action.
- **D-470:** The schema prefix comes from the helper-routed cache lookup. The edit prepends only `<schema>.` to the current identifier range, preserving the user's table spelling and quote style.
- **D-471:** If the schema exact name needs quoting or the original table identifier is quoted, render the schema using the same quote-preserving renderer instead of local case folding.

### Refresh And Reload Commands

- **D-472:** `Refresh schema cache` returns command id `dbee/refresh_schema` with arguments containing at least `conn_id`, cache generation, and root epoch.
- **D-473:** `Reload table metadata` returns command id `dbee/reload_table` with `conn_id`, `schema`, `table`, quote flags, cache generation, and root epoch.
- **D-474:** `workspace/executeCommand` accepts only enabled, advertised dbee command ids. Unknown or disabled commands are protocol-safe no-ops or errors and must not reach handler APIs.
- **D-475:** Command execution rechecks the per-command enabled flag, active connection, authority scope, cache generation, and root epoch before scheduling work. Stale command arguments are rejected.
- **D-476:** Commands return immediately after scheduling existing async refresh/reload work. They do not wait for database responses or perform synchronous metadata calls.
- **D-477:** Schema refresh invalidates only the active connection cache and routes through the existing LSP root-refresh flow so schema-filter authority still controls scope.
- **D-478:** Table reload schedules an async column reload for the resolved in-scope table. If current cache internals only return cached columns, add a small schema-cache command helper that intentionally bypasses the cached hit while retaining epoch/generation admission on writes.

### Fail-Closed And Safety

- **D-479:** Authority-unavailable returns an empty action list. Legacy authority-API absence keeps the existing implicit-all behavior.
- **D-480:** Stale root epoch returns an empty action list for discovery, including source actions.
- **D-481:** Out-of-scope schemas, missing cache data, unknown identifiers, unsupported ranges, and ambiguity return empty lists rather than disabled actions.
- **D-482:** Text edits are single-document, single-range, versioned `documentChanges`. Phase 12.3 does not produce multi-file edits, overlapping edits, or server-initiated `workspace/applyEdit`.
- **D-483:** Multi-statement same-line SQL uses the Phase 12.2 quote/comment-aware statement splitter. Semicolons in strings, comments, or dollar-quoted strings are not statement boundaries.
- **D-484:** New code-action code must not introduce direct helper bypasses: no raw schema-filter interpretation, no direct epoch reads, no local canonical folding, and no request-path `connection_get_*`. Revision 1 also scans new `init.lua` command callback bodies.
- **D-485:** Phase 12.3 rollup is strict and exactly-once. Revision 2 locks 43 rollup-checked markers and 45 emitted Phase 12.3 markers including `LSP12_3_ROLLUP_MARKERS_CHECKED` and `LSP12_3_ALL_PASS`.

## Deferred Ideas

- Format SQL.
- Generate JOIN.
- Add LIMIT.
- Lazy `codeAction/resolve`.
- Multi-table `SELECT *` expansion with aliases.
- CTE-aware and subquery-aware SQL refactors.
- Client-side Neovim command implementations.

## Canonical References

- `.planning/DISCUSS-phase12.md` - Phase 12 umbrella decisions, especially D-318 and D-331.
- `.planning/phases/12-lsp-feature-gap-closure/12-01-PLAN.md` - Phase 12.1 helper and epoch invariants.
- `.planning/phases/12-lsp-feature-gap-closure/12-02-PLAN.md` - Phase 12.2 parser, symbol, authority, and marker lessons.
- `.planning/REQUIREMENTS.md` - DBEE-FEAT-02.
- `.planning/ROADMAP.md` - v1.3 conditional LSP feature-gap closure.
- `lua/dbee/lsp/server.lua` - LSP request dispatcher and capability advertisement.
- `lua/dbee/lsp/init.lua` - active connection, schema refresh, invalidation, and async event ownership.
- `lua/dbee/lsp/context.lua` - statement splitting, token/range parsing, and table-reference extraction.
- `lua/dbee/lsp/schema_cache.lua` - helper-routed metadata reads and async column loading.
- `lua/dbee/schema_filter_authority.lua` - schema scope authority.
- `lua/dbee/schema_name_canonical.lua` - adapter-aware canonical and unquoted-name decisions.
- `lua/dbee/lsp/epoch_authority.lua` - root-epoch freshness and write admission.

---

*Phase: 12.3-lsp-code-actions*
*Context gathered: 2026-05-01*
