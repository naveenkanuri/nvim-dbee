# Known Issues

## v1.3 Backlog

### Pending milestone v1.3 candidates

- **Phase 12: LSP feature gap closure** — deferred from v1.2 per "DECIDE AT PHASE 11 SHIP" clause. Scope: `completionItem/resolve` lazy details, hover for table/column metadata, code actions for refresh/reload on stale schema, document/workspace symbol for schema objects. Out: semantic tokens, inlay hints, `vim.lsp.config()` migration, multi-client LSP architecture (those defer further).

### Pre-existing bugs surfaced during v1.2 work (NOT Phase 10/11 caused)

- **`a and nil or b` Lua pattern cleanup**:
  - `lua/dbee/handler/init.lua:780`
  - `lua/dbee/ui/drawer/init.lua:1904`
  - Lua truthiness bugs where middle expression being falsy selects the wrong branch.

- **Pre-existing legacy headless failures**, verified on both `50b53eb` (Phase 10 ship) and `74bd66f` (mid-Phase 11):
  - `check_actions_recovery.lua` — `ACTIONS_RECOVERY_FAIL=recover_execute_timeout`
  - `check_auto_reconnect.lua` — `CONN01_FAIL=deep_copy_retry_ok:false`
  - `check_notifications.lua` — `NOTIF_FAIL=notif04_add_node_not_found`
  - `check_drawer_yank.lua` — `CLIP02_FAIL=a10_connection_node_present`

### Phase 11 r6 residual HIGH (backlogged after diminishing-returns gate at impl-gate r6)

- **Case-colliding schema lookup mismatch** (`lua/dbee/lsp/schema_cache.lua:373`, `lua/dbee/lsp/server.lua:86`):
  Incremental `_upsert_table_index()` is not fully rebuild-equivalent when schemas differ only by case. Existing folded schema representative can survive, causing completion to read `a.T` while async sync-delivery stored `A.T`.
  v1.3 fix: update `schema_lookup` incrementally using the same representative rule as full rebuild; extend equivalence tests to compare lookup indexes.

- **Targeted global index update still walks schemas** (`lua/dbee/lsp/schema_cache.lua:332`):
  `_update_global_table_index_for_label()` avoids full global refresh but still sorts/scans all schemas per async-discovered table.
  v1.3 fix: maintain an incremental representative map per folded label so each upsert only compares the affected schema/table.

### v1.1 Phase 7 drawer UX polish (surfaced 2026-04-29 during v1.1 live test)

- **Connection source badge always shown even when single-source (visual noise)** (`lua/dbee/ui/drawer/convert.lua` per Phase 7 D-65):
  D-65 wording: "may display a lightweight source badge or suffix **for disambiguation**". Implementation emits `[<source_id>]` suffix on every connection row unconditionally. With a single-source setup (only `connections.json`), every row shows the same `[connections.json]` (truncated to `[connecti...]` in narrow drawer width) — pure noise, no disambiguation value.
  v1.3 fix: make badge conditional on `count(distinct source_id) > 1`. Single-source = clean flat list. Multi-source keeps the badge where it actually disambiguates. Threshold rule itself is a small discuss-phase decision (only-if-multi vs always-on toggle vs config option).

- **Drawer cold start lacks visual orientation** (cosmetic, related):
  Connection list starts flat from line 1. Old v1.0 had `connections.json` parent header providing instant context for "what am I looking at". v1.3 candidate: optional section header `Connections` line OR active-connection highlight at top. Lower priority than badge fix.
