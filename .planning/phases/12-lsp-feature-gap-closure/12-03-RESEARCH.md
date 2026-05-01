# Phase 12.3: LSP Code Actions - Research

**Researched:** 2026-05-01
**Status:** Ready for planning
**Base HEAD:** `692f64a`

## Protocol Research

### `textDocument/codeAction`

- Request method: `textDocument/codeAction`.
- Params include `textDocument`, `range`, and `context`.
- Result shape: `(Command | CodeAction)[] | null`.
- A `CodeAction` must include at least an `edit`, a `command`, or both.
- Standard kinds needed here are `refactor.rewrite` and `source`.
- Server capability is `codeActionProvider = true` or `CodeActionOptions`.
- Phase 12.3 does not need `codeAction/resolve` because edit construction is cache-only and bounded.

### `workspace/executeCommand`

- Request method: `workspace/executeCommand`.
- Server capability is `executeCommandProvider.commands`.
- Neovim forwards unknown LSP command ids to the server when `workspace/executeCommand` is supported, so refresh/reload command actions need server-side handling.
- Phase 12.3 should avoid client-local `vim.lsp.commands` dependencies.

### WorkspaceEdit

Use current-document single edits carried inside versioned `documentChanges`, not unversioned `changes`:

```lua
{
  documentChanges = {
    {
      textDocument = {
        uri = uri,
        version = current_version,
      },
      edits = {
        {
          range = range,
          newText = "id, name, email",
        },
      },
    },
  },
}
```

The server does not apply edits itself. It tracks synced document versions from `didOpen`/`didChange` and embeds the current version in edit actions. The client applies returned WorkspaceEdits according to LSP behavior; stale versions must reject or no-op when `vim.lsp.util.apply_workspace_edit` sees that the buffer advanced after action discovery.

## Local Code Research

### Server Dispatcher

`lua/dbee/lsp/server.lua` already centralizes:

- initialize capability advertisement,
- request routing,
- full-sync text document lifecycle,
- diagnostics debouncing,
- document/workspace symbol invalidation,
- feature config extraction.

Recommended integration:

- Require `dbee.lsp.code_actions`.
- Add feature config for master and per-action toggles.
- Advertise `codeActionProvider` and `executeCommandProvider`.
- Route `textDocument/codeAction` to `code_actions.handle_code_action(params, cache, opts)`.
- Route `workspace/executeCommand` to `code_actions.execute_command(params, cache, opts)`.

### LSP Init And Command Ownership

`lua/dbee/lsp/init.lua` owns the active connection, cache invalidation, root refresh, and async event handlers. Command actions should not call init globals from `code_actions.lua` directly.

Recommended shape:

- Pass a `code_action_commands` table from `init.lua` into `server.create(cache, opts)`.
- `refresh_schema` callback checks active connection, invalidates active cache, and calls the existing `_request_root_refresh(handler, conn_id)`.
- `reload_table` callback checks active connection and calls a schema-cache async reload helper.
- Both callbacks return immediately after scheduling.

This keeps server protocol code thin and keeps refresh ownership in `init.lua`.

### Schema Cache

Existing cache helpers already cover most read paths:

- `read_lsp_authority()`
- `_fresh_lsp_scope()`
- `get_table_metadata(schema, table, opts)`
- `find_schema`, `find_table`, `find_table_in_schema`
- `get_columns_async(schema, table, opts)`
- `invalidate()`
- `metadata_root_epoch()`

Gap for table reload:

- `get_columns_async` returns a cached hit and does not force a reload.
- Add `SchemaCache:reload_table_metadata_async(schema, table, opts)` or equivalent.
- The helper must first validate `_fresh_lsp_scope()`, resolve exact schema/table in scope, capture root epoch, then schedule the existing async column path with a reload/force mode.
- Writes continue through `on_columns_loaded` and existing epoch admission.

### Context Parser

`lua/dbee/lsp/context.lua` already provides:

- quote/comment/dollar-string-aware `extract_statements`,
- `statement_offset_to_position`,
- identifier token parsing,
- `token_at_position`,
- token-aware `statement_table_refs`,
- source-symbol extraction built on those refs.

Recommended additions:

- `code_action_context(params)` or smaller helpers returning the request statement, token/star at range, and table refs.
- `select_star_at_range(statement, range)` that recognizes only an unqualified top-level `*` in the select list before `FROM` and rejects `alias.*` / multi-part qualified stars.
- `table_ref_at_range(statement, range)` that returns the table-ref component under cursor/range.
- `single_table_ref(statement)` that returns nil unless exactly one table ref exists.
- `cte_names(statement)` that extracts token-aware `WITH name AS (...)` local relation names so qualify/reload can reject shadowed table identifiers.

Keep hover's 200-line bounded scan separate. Code actions should use the current statement from the full synced buffer and the request range.

## Action Research

### Expand SELECT *

Inputs:

- request range over `*`,
- current statement,
- exactly one table ref,
- fresh helper-routed table metadata with loaded columns,
- column count at or under `lsp.code_action_max_expand_columns`.

Output:

- `CodeAction` title `Expand SELECT * -> list columns`,
- kind `refactor.rewrite`,
- one WorkspaceEdit replacing `*` with rendered column names.

Omit action when:

- request range is not on `*`,
- request range is on a qualified wildcard such as `u.*` or `schema.table.*`,
- `*` is outside a select list,
- statement has multiple table refs,
- selected `FROM` relation matches a CTE/local relation name in the active statement,
- cache is stale, authority unavailable, table is filtered, table metadata missing, columns missing, or table is too wide.

### Qualify Identifier

Inputs:

- request range over an unqualified table identifier,
- fresh helper-routed table resolution,
- unique schema/table match.

Output:

- title `Qualify identifier: users -> public.users`,
- kind `refactor.rewrite`,
- one WorkspaceEdit prepending rendered schema plus `.`.

Omit action when:

- token is already qualified,
- token is an alias or column,
- token matches a CTE/local relation name in the active statement,
- global resolution is ambiguous,
- resolved schema is filtered or stale,
- quote rendering cannot preserve exact user intent.

### Refresh Schema Cache

Inputs:

- enabled source-action toggle,
- active connection/cache,
- authority and epoch gates pass.

Output:

- title `Refresh schema cache`,
- kind `source`,
- command id `dbee/refresh_schema`,
- args with `conn_id`, root epoch, cache generation.

Execution:

- Recheck active connection and command token.
- Invalidate active cache.
- Schedule existing root refresh.
- Return nil immediately.

### Reload Table Metadata

Inputs:

- request range over a known cached table identifier,
- resolved schema/table are in current scope,
- selected identifier is not a CTE/local relation shadow,
- enabled source-action toggle.

Output:

- title `Reload table metadata`,
- kind `source`,
- command id `dbee/reload_table`,
- args with `conn_id`, schema, table, quote flags, root epoch, cache generation.

Execution:

- Recheck active connection, authority, root epoch, and cache generation.
- Schedule table-specific async column reload.
- Return nil immediately before any column result callback or write admission completes.

## Helper And Security Research

| Risk | Existing guard | Phase 12.3 application |
| --- | --- | --- |
| Schema-filter bypass | `schema_filter_authority` via schema-cache authority helpers | Code-action discovery and reload command require fresh in-scope cache reads. |
| Case/quote leaks | `schema_name_canonical` | Rendering uses canonical helper to decide whether exact names are safe unquoted. |
| Stale cache | `epoch_authority` | Discovery returns empty when root epoch is stale; commands reject stale args. |
| Request-path DB calls | Phase 10/11/12.1 counters | `textDocument/codeAction` must not call sync or async handler DB APIs. |
| Wide-table edits | bounded preview/copy | Omit expand action above the configured column cap. |
| Multi-statement SQL | Phase 12.2 statement splitter | Use token-aware statement range, not raw regex over full text. |

## Performance Research

Discovery can meet P95 <50ms if it:

- reads one buffer line/statement and one cache record,
- uses token/range matching,
- avoids full-document symbol parsing,
- avoids deep-copying large metadata tables,
- caps column expansion before building strings.

Edit construction can meet P95 <100ms because expand/qualify each produce a single text edit. The worst case is column-list rendering for a table at the configured cap.

Recommended Phase 12.3 perf cohorts:

1. codeAction on no-action refactor range.
2. codeAction expand-star cached table.
3. codeAction qualify identifier.
4. codeAction source-command discovery.

Emit `LSP12_3_PERF_SCENARIOS_COUNT=4`, `LSP12_3_MEASURED_COUNT=100`, and the four rollup-checked per-cohort metric markers:

- `LSP12_3_CODEACTION_EMPTY_REFACTOR_RANGE_P95_MS`
- `LSP12_3_CODEACTION_EXPAND_SELECT_STAR_P95_MS`
- `LSP12_3_CODEACTION_QUALIFY_IDENTIFIER_P95_MS`
- `LSP12_3_CODEACTION_SOURCE_COMMANDS_P95_MS`

## Test Strategy

Add `ci/headless/check_lsp12_3_code_actions.lua` for functional sentinels, then extend:

- `ci/headless/check_lsp12_rollup.lua` with strict Phase 12.3 marker checks.
- `ci/headless/check_lsp_perf.lua` with Phase 12.3 perf cohorts.
- `Makefile` so `make perf-lsp PERF_PLATFORM=macos` runs the new sentinel before rollup.

Request-path counters must wrap `textDocument/codeAction`. Execute-command counters are separate because refresh/reload intentionally schedule async work after user selection.

## Open Implementation Notes For Planner

- Keep code-action response construction in a new module; keep refresh/reload ownership in `init.lua` callbacks.
- Prefer adding small context helpers over embedding SQL parsing in `code_actions.lua`.
- Prefer adding one named schema-cache command helper for table reload over calling handler APIs from server code.
- Static helper-bypass sentinels should scan `code_actions.lua`, new context helper bodies, the new schema-cache reload helper, `server.lua` execute-command dispatch, and new `init.lua` command-handler bodies with scoped allow-lists for command-path async scheduling.
- User docs should mention `vim.lsp.buf.code_action()` and the new rollback/per-action flags, not prescribe a project-specific keymap.

## References

- Official Language Server Protocol 3.17 specification: `textDocument/codeAction`, `CodeAction`, `CodeActionKind`, `WorkspaceEdit`, `workspace/executeCommand`, and `executeCommandProvider`.
- Neovim LSP help: `vim.lsp.buf.code_action()` and command forwarding behavior.
- `.planning/DISCUSS-phase12.md`
- `.planning/phases/12-lsp-feature-gap-closure/12-01-PLAN.md`
- `.planning/phases/12-lsp-feature-gap-closure/12-02-PLAN.md`
- `lua/dbee/lsp/server.lua`
- `lua/dbee/lsp/init.lua`
- `lua/dbee/lsp/context.lua`
- `lua/dbee/lsp/schema_cache.lua`
- `lua/dbee/schema_filter_authority.lua`
- `lua/dbee/schema_name_canonical.lua`
- `lua/dbee/lsp/epoch_authority.lua`
