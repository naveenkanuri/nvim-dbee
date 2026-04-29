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

### v1.1 Phase 7 drawer filter regression (surfaced 2026-04-29 during v1.1 live test) — HIGH

- **`/` filter in drawer fails on connection-only root** (`lua/dbee/ui/drawer/menu.lua` filter path; Phase 4 D-31 + Phase 7 D-67/D-68 inheritance):
  Pressing `/` in the drawer (with no connection bootstrapped yet, just the flat connection list) emits "No cached connections available for filter" and exits filter mode. User can't reach a specific connection by typing.
  Likely root cause: Phase 7 connection-only-root rewrite kept Phase 4 D-31 filter contract that operates over `_struct_cache` (per-connection structure). On the connection list itself (no conn bootstrapped, `_struct_cache` empty), filter early-returns instead of falling back to filtering the visible connection rows by name.
  Expected: `/` filters whatever's currently visible — connection rows pre-bootstrap (by name + source badge), structure rows under expanded conn (by schema/table/column name).
  v1.3 fix: extend filter to operate on visible row set when `_struct_cache` empty for current root. Keep Phase 4 D-31 filter-exit contract intact. New unit test covering connection-list-only filter case.
  Severity: **HIGH** — primary navigation pattern broken. Workaround: scroll/jump manually (`gg`/`G`/`/conn_name` via vim-search not drawer filter).

### v1.1 Phase 8 wizard highlight regression (surfaced 2026-04-29 during v1.1 live test) — UNUSABLE on dark colorschemes

- **Wizard input field text invisible (text fg = bg)** (`lua/dbee/ui/wizard/*` or wherever Phase 8 compound modal lives):
  Typing into the Name field shows cursor moving but typed characters don't render. Type/Mode dropdown either doesn't render or renders text on dark-on-dark. Repro: open Add Connection wizard, type any name → cursor advances, text invisible.
  Likely root cause: nui.nvim Input/Select components in the wizard lack explicit `winhighlight` config. Inherits `Normal` over `NormalFloat` where fg/bg collide on user's dark colorscheme. Phase 8 D-XX may have defined highlight contract but implementation skipped applying it to child windows.
  v1.3 fix: explicit `winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,..."` on each wizard Input/Select component. Test against multiple dark colorschemes (Naveen's current scheme + e.g. tokyonight, catppuccin-mocha, gruvbox-dark) before close.
  Severity: **HIGH** — wizard is a headline v1.1 deliverable but unusable on Naveen's daily colorscheme. Workaround: edit `connections.json` directly to add connections.

### v1.2 Phase 11 LSP cache migration UX (surfaced 2026-04-29 during v1.1 live test) — POLISH

- **"corrupt cache" warning fires on first v1.2 run for pre-v1.2 cache files** (`lua/dbee/lsp/schema_cache.lua` `load_from_disk`):
  Phase 11 r2 CRIT 2 fix added schema-index shape validation. Pre-v1.2 cache files at `~/.local/state/nvim/dbee/lsp_cache/<conn_id>.json` were written with a slightly different shape and fail new validation → recovery path fires (warn + delete + structure refresh). The warning text "corrupt cache while loading schema index: <path>" is alarming — sounds like data loss when really it's a one-time format upgrade.
  Expected user impact: warning fires ONCE per connection on first v1.2 run; cache regenerates fresh from structure refresh; subsequent runs silent.
  Repro: any user upgrading from v1.1 → v1.2 with existing `lsp_cache/*.json` files. Naveen hit it on `nkanuri6` and likely others.
  v1.3 fix options:
  1. Add a schema-version field to cache JSON (`{ "version": 2, ... }`). Migrate old → new on first read instead of delete.
  2. Detect missing-version-field as v1 format → silent log (`vim.log.levels.DEBUG`) + delete + refresh, instead of WARN-level "corrupt cache".
  3. Both: detect-and-migrate where field shapes are recoverable, silent-delete-and-refresh where not.
  Severity: **POLISH** — recovery path works correctly (data not lost; cache regenerates). Just bad first-run UX. Pick option 1+3 hybrid for cleanest user experience on v1.3 upgrade path.
