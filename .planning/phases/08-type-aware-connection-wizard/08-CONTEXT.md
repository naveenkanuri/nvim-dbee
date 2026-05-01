# Phase 8: Type-Aware Connection Wizard - Context

**Gathered:** 2026-04-28
**Status:** Locked — ready for planning

<domain>
## Phase Boundary

Phase 8 adds a type-aware add/edit wizard for saved connections on top of the shipped Phase 7 connection-only drawer and lifecycle contracts. It covers Oracle Cloud Wallet, Oracle Custom JDBC/TNS descriptor, Postgres URL, and Postgres Form flows; performs a real non-mutating driver ping before save; and hardens FileSource persistence with atomic fail-closed writes plus round-trip-safe metadata preservation.

In scope:
- Wizard-based add/edit UX reached from Phase 7 `a` and `e`
- Oracle and Postgres mode-specific forms, plus a compatibility raw path for existing non-Oracle/Postgres entries
- Lossless round-trip of the user's original wizard input
- Pre-save driver ping for unsaved specs
- Atomic FileSource JSON writes that preserve prior file state on failure
- Reuse of the Phase 7 eventful source mutation and invalidation contract after successful save

Out of scope:
- Reopening Phase 6 `_struct_cache`, `caller_token`, `root_epoch`, or other STRUCT-01 contracts
- Reopening Phase 7 D-64..D-88 lifecycle ownership, invalidation, reconnect, or drawer/LSP coordination contracts
- New adapter-specific wizard support beyond Oracle and Postgres
- Encrypted password storage, secret-manager integration, or wallet file management UI
- Phase 9 real-`nui.nvim` perf work

</domain>

<decisions>
## Implementation Decisions

### Wizard Surface And Entry Flow
- **D-89:** Phase 8 keeps Phase 7 D-67/D-68 intact: `a` and `e` remain the only primary add/edit entry points. Those entry points open the wizard: scoped Oracle/Postgres rows land in their typed mode sets, while editable connections outside that scoped set land in the wizard's generic `Other` compatibility mode rather than regressing edit capability. There is no separate legacy raw-prompt save path, and raw compatibility submits remain plain records without wizard metadata.
- **D-90:** The wizard UI uses a dedicated compound `nui.nvim` modal rather than chained `vim.ui.input()`, `common.float_prompt()`, or a loose stack of single-input popups.
- **D-91:** Flow is fixed as: source selection per Phase 7 D-68, then type picker (`Oracle`, `Postgres`, `Other`), then mode picker, then the mode-specific form. Edit starts with the saved type and mode when wizard metadata exists, but type and mode remain changeable from the wizard header instead of separate `a-oracle-*` or `e-postgres-*` entry points.
- **D-92:** Validation is hybrid. The wizard performs cheap local validation as the user progresses or submits, while authoritative validation stays at final submit via a real driver ping.
- **D-93:** Connection `name` is an explicit required field in every mode. The wizard may suggest a default from host, service, or alias, but it never silently derives or rewrites the persisted name on submit.

### Ping And Save Gating
- **D-94:** Phase 8 adds a transient-spec connection-test path instead of trying to reuse the persisted-`conn_id` D-82 RPC for new unsaved entries. The public Lua surface may overload `dbee.connection_test()` to accept either `conn_id` or an unsaved spec, but the underlying implementation stays non-mutating: no current-connection swap, no source mutation, no `_struct_cache` effects, and no file writes.
- **D-95:** Submit flow is fixed as: local validation, transient driver ping, atomic source mutation, then the existing Phase 7 eventful reload/invalidation path. All add/edit save paths, including `Other` / raw-compatibility edits, use this same gate. If mutation commits but the reload step fails, the saved file remains authoritative and the implementation emits both `connection_invalidated` and `source_reload_failed` per Phase 7 D-83.
- **D-96:** Add/edit save does not implicitly activate or switch the current connection. Activation remains a separate user action (`<C-CR>` or a future explicit affordance) so Phase 8 preserves Phase 7 D-69 current-selection stability and avoids surprise structure reloads.

### Round-Trip Persistence Model
- **D-97:** Phase 8 preserves the runtime connection contract `{ id, name, type, url }` and adds wizard-specific source metadata instead of widening core `ConnectionParams`. FileSource JSON entries gain an additive metadata block that stores `db_kind`, `mode`, and the original user-entered fields needed to reopen the wizard losslessly. That metadata persists only for FileSource-backed scoped Oracle/Postgres wizard modes; all raw compatibility submits, including FileSource `Other` or raw-fallback saves, remain plain `{ name, type, url }` records.
- **D-98:** Edit seeding prefers stored wizard metadata. If metadata is absent, the wizard does best-effort parsing from existing `type` plus `url` only when the parse can reopen the connection without lossy normalization; otherwise it falls back to a raw mode (`Postgres URL`, `Oracle Custom JDBC` raw text, or generic `Other`) instead of inventing normalized form data.
- **D-99:** FileSource writes become atomic temp-file-plus-rename writes in the same directory. Any encode, write, close, or rename failure leaves the original `connections.json` untouched and surfaces an actionable error through the existing Phase 7 failure path.
- **D-100:** FileSource update preserves untouched sibling records and unknown fields on the edited record, including future metadata and manually-added fields, rather than rebuilding the row from only `name`, `type`, and `url`. Explicit deletion is separate from omission: updates that intentionally remove keys, such as deleting stale `wizard` metadata when a row moves into raw compatibility, use a documented delete directive rather than relying on merge omission. Comment and whitespace preservation are explicitly not promised; semantic field preservation is.

### Mode Coverage And Field Semantics
- **D-101:** The supported mode set is fixed for Phase 8: Oracle Cloud Wallet, Oracle Custom JDBC/TNS descriptor, Postgres URL, Postgres Form, plus a generic `Other` raw `name/type/url` compatibility mode. The `Other` mode is the compatibility surface for non-Oracle/Postgres or lossy-fallback cases, not a separate prompt architecture or new adapter feature work.
- **D-102:** Oracle Cloud Wallet mode accepts explicit `name`, `username`, `password`, wallet path (directory or `.zip`), and service alias. Wallet service discovery from `tnsnames.ora` is assistive, not blocking: when parsing succeeds, the wizard offers a dropdown; when parsing fails or the desired alias is absent, manual alias entry remains available with a warning.
- **D-103:** Oracle Custom JDBC mode treats the TNS descriptor string as opaque user-owned input that must round-trip verbatim. Local validation is lightweight, while the driver ping is the authoritative validator. The saved runtime URL or DSN may be generated from this raw input during save and test, but the original descriptor remains in the wizard metadata.
- **D-104:** Postgres URL mode stores and reopens the exact user-entered URL string. Postgres Form mode stores decomposed fields (`host`, `port`, `database`, `username`, `password`, `sslmode`) plus the exact rendered URL it produced at save time. When an existing Postgres URL contains unsupported extra query parameters, the wizard falls back to URL mode instead of silently dropping them in Form mode.
- **D-105:** Passwords follow the existing FileSource cleartext model for Phase 8. Wizard password inputs are masked in the UI, but save writes literal values unless the user explicitly types an environment placeholder string, which is preserved verbatim and never auto-templated or auto-expanded during save.

### Phase 7 Compatibility
- **D-106:** Phase 7 D-66 remains visible: source-file editing stays reachable as an additive secondary action outside the wizard, and Phase 8 help text may point to it as the advanced/manual escape hatch for unsupported fields. The wizard does not replace or hide that surface.

### the agent's Discretion
- Exact wizard chrome (single popup vs popup plus footer/help row) as long as it remains compound, modal, and keyboard-first per D-90.
- Exact field order within each mode once `name` stays explicit and the required fields above remain intact.
- Exact wording and severity split for validation, ping, and save messages as long as Phase 7 D-69 actionable-feedback rules hold.
- The exact name of the additive FileSource metadata block (`wizard`, `ui`, or similar), as long as it remains source-local and outside core `ConnectionParams`.
- Whether the generic compatibility branch is labeled `Other`, `Raw`, or `Advanced`, as long as it clearly does not promise new adapter-specific wizard support.

</decisions>

<specifics>
## Specific Ideas

- Oracle Cloud Wallet mode should feel like the "happy path" for Naveen's dominant Oracle setup: `name`, `username`, masked `password`, wallet path, service alias, then any SSL-related toggles behind an "Advanced" foldout rather than in the main form.
- Oracle Custom JDBC mode should use a larger multiline field for the raw descriptor string so the user edits the original `(DESCRIPTION=...)` text directly instead of fighting a single-line input.
- Postgres URL mode should preserve the exact text the user typed, including query-string ordering and placeholder values, and edit should reopen that exact string rather than a reserialized `url.String()` output.
- Postgres Form mode should default `port` to `5432` and expose only the scoped fields (`host`, `port`, `database`, `username`, `password`, `sslmode`) in Phase 8. Unsupported extra URL parameters should force URL mode instead of quietly disappearing.
- Legacy or unsupported rows should enter the wizard through a clearly-labeled raw compatibility mode rather than bouncing the user back to a completely different prompt UI with no explanation.
- The wizard should make the advanced/manual escape hatch obvious: a short help line can mention that source-file editing still exists for power users who want to hand-edit JSON.
- The save affordance should read as one action that implicitly performs the ping first, rather than teaching two separate steps for the common path.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Scope And Milestone Locks
- `.planning/PROJECT.md` — milestone goal, backward-compatibility rule, FileSource hardening scope, and the additive-only constraint
- `.planning/ROADMAP.md` — Phase 8 goal, success criteria, research bullets, and the two open DCFG-02 product questions this context closes
- `.planning/REQUIREMENTS.md` — `DCFG-02` requirement text and v1.1 out-of-scope statements
- `.planning/STATE.md` — current milestone sequencing and the recorded DCFG-02 gray areas

### Locked Prior-Phase Decisions
- `.planning/phases/04-drawer-navigation/04-CONTEXT.md` — Phase 4 D-31 filter snapshot restore and drawer interaction baseline
- `.planning/phases/05-resilience-diagnostics/05-CONTEXT.md` — Phase 5 D-07 and D-29 reconnect/current-context guarantees that Phase 8 must preserve
- `.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md` — Phase 6 D-30..D-63, especially D-60's narrowed scope and the fixed `_struct_cache` substrate
- `.planning/phases/07-connection-only-drawer/07-CONTEXT.md` — Phase 7 D-64..D-88, especially D-67, D-68, D-69, D-71, D-82, D-83, and D-88

### Code Seams To Reuse
- `lua/dbee/ui/drawer/init.lua` — current add/edit entry points, `prompt_connection_details`, source selection, and secondary source-file editing surface
- `lua/dbee/ui/drawer/convert.lua` — existing connection-row edit/delete action wiring and current `connection_get_params()` dependency
- `lua/dbee/ui/drawer/menu.lua` — current `nui.nvim` select/input/filter primitives and their limitations
- `lua/dbee/ui/common/floats.lua` — current prompt/editor float helpers that the wizard may supersede
- `lua/dbee/sources.lua` — current FileSource load/create/update/delete behavior that Phase 8 hardens
- `lua/dbee/handler/init.lua` — canonical source mutation wrappers and current Lua `connection_test()` wrapper
- `dbee/handler/handler.go` — Go-side `ConnectionTest` implementation and runtime connection APIs
- `dbee/endpoints.go` — RPC manifest seams for any additive transient-spec ping endpoint
- `dbee/core/connection_params.go` — current runtime `{ id, name, type, url }` shape that cannot carry full wizard metadata
- `lua/dbee/doc.lua` — public type and event docs that must stay in sync if Phase 8 adds a new ping surface or metadata-aware helper

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lua/dbee/ui/drawer/init.lua` already centralizes add/edit entry through `open_add_connection()` and `open_edit_connection()`, so Phase 8 can replace the prompt body without changing Phase 7 key routing.
- `lua/dbee/ui/drawer/menu.lua` shows the project already depends on `nui.nvim` for popup selection/input/filter surfaces, which makes a custom compound wizard a natural extension instead of a new UI stack.
- `lua/dbee/handler/init.lua` plus `dbee/handler/handler.go` already provide the canonical source mutation and connection-test seams; the wizard should enter through those rather than inventing a drawer-only save path.
- `common.float_editor(source_meta.file, ...)` is already the shipped secondary source-file-edit path that Phase 7 D-66 preserved.

### Established Patterns
- Phase 7 D-83 already locked mutation-first, reload-second partial-failure semantics, so the wizard must reuse `source_add_connection()` and `source_update_connection()` after the pre-save ping instead of hand-writing file persistence from the drawer layer.
- Current FileSource CRUD is source-owned, which means atomic writes and unknown-field preservation belong in `lua/dbee/sources.lua`, not in the drawer or handler layer.
- Current edit seeding goes through `connection_get_params()`, but that surface only returns `name/type/url`. True round-trip for wallet, descriptor, and form modes therefore requires additive source-local metadata access rather than trying to widen the runtime connection model.
- `menu.lua` and `float_prompt()` only support single-input or flat key/value editing today; neither covers masked passwords, dependent field visibility, or mode switching cleanly.

### Integration Points
- `lua/dbee/ui/drawer/init.lua` is the primary seam for swapping `prompt_connection_details()` out for the wizard while preserving Phase 7 add/edit actions and source preselection.
- `lua/dbee/ui/drawer/convert.lua` currently wires edit actions directly to `connection_get_params()` and raw prompt fields; Phase 8 will need a metadata-aware edit loader for FileSource-backed rows.
- `lua/dbee/sources.lua` currently overwrites files with `io.open(path, "w+")` and only updates `name`, `url`, and `type`, which is exactly the persistence seam Phase 8 must harden.
- `dbee/core/connection_params.go` confirms the runtime connection shape is intentionally small, which is why the metadata-preservation strategy has to live at the source layer.
- `dbee/endpoints.go` and `lua/dbee/handler/init.lua` are the additive RPC seam for transient pre-save ping if the planner decides not to overload the existing D-82 wrapper directly.

</code_context>

<deferred>
## Deferred Ideas

- Encrypted password storage, OS keychain integration, or secret-manager backends
- Wallet file management UX beyond accepting a user-provided path
- Adapter-specific wizard coverage beyond Oracle and Postgres
- Automatic activation immediately after save
- Preservation of JSON comments or formatting beyond semantic field preservation
- Rich support for arbitrary Postgres query parameters in Form mode beyond the scoped `sslmode` field
- Any reopening of Phase 6 `_struct_cache` shape or Phase 7 lifecycle ownership to make the wizard work

</deferred>

---

*Phase: 08-type-aware-connection-wizard*
*Context gathered: 2026-04-28*
