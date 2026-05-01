---
phase: 08-type-aware-connection-wizard
plan: 02
subsystem: ui
tags: [wizard, nui, oracle, postgres]

requires:
  - phase: 08-type-aware-connection-wizard
    provides: FileSource raw-record access and metadata-preserving persistence helpers
provides:
  - compound connection wizard modal with Oracle/Postgres/Other modes
  - lossless seed normalization and serializer helpers for scoped wizard modes
  - wallet alias discovery plus masked password editing inside the wizard surface
affects: [08-03, 08-04]

tech-stack:
  added: []
  patterns:
    - "Single compound nui modal owns type, mode, and mode-local field state"
    - "Metadata-first seeding with lossless parse fallback before raw compatibility fallback"
    - "Wallet alias discovery stays assistive while driver ping remains authoritative"

key-files:
  created: []
  modified:
    - lua/dbee/ui/connection_wizard/init.lua
    - lua/dbee/doc.lua

key-decisions:
  - "D-91/D-101: all supported connection modes live in one wizard surface with explicit type and mode selectors"
  - "D-98/D-104: Postgres seeds normalize into form mode only when the rendered URL matches exactly; otherwise they stay in URL/raw compatibility"
  - "D-102/D-103/D-105: wallet alias discovery is best-effort, Oracle descriptor input stays opaque, and masked password editing preserves literal bytes in wizard state"

requirements-completed: [DCFG-02]

duration: 1 session
completed: 2026-04-28
---

# Phase 8 Plan 02: Wizard Surface Summary

**Phase 8 now has a real type-aware connection wizard that can reopen Oracle and Postgres connections without inventing lossy form state.**

## Performance

- **Completed:** 2026-04-28
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Built the compound `nui.nvim` wizard shell with Oracle Cloud Wallet, Oracle Custom JDBC, Postgres URL, Postgres Form, and `Other` raw compatibility modes in one surface.
- Added wallet alias discovery for wallet directories and `.zip` files, plus multiline descriptor editing and masked password entry inside the wizard overlay instead of bouncing back to raw prompts.
- Implemented metadata-first seeding, Postgres/Oracle lossless parse helpers, and per-mode serializers so later submit wiring can ping and persist a normalized `{ params, wizard }` payload without re-deriving mode state.

## Task Commits

1. **Task 08-02-01: Create the compound wizard modal and mode-state machine** - `8f96cd5` (feat)
2. **Task 08-02-02: Implement mode serializers, local validation, and lossless seed normalization** - `fd24e91` (feat)

## Verification Results

- `08-02-01` verify block passed on 2026-04-28: `oracle_cloud_wallet`, `tnsnames`, `wallet_path`, `service_alias`, `oracle_custom_jdbc`, `postgres_url`, `postgres_form`, `other_raw`, and `function M.open` are present in `lua/dbee/ui/connection_wizard/init.lua` and `lua/dbee/doc.lua`.
- `08-02-02` verify block passed on 2026-04-28: `validate`, `serialize`, `normalize_seed`, `rendered_url`, `unsupported query`, `lossless`, and `placeholder` are present in `lua/dbee/ui/connection_wizard/init.lua` and `lua/dbee/doc.lua`.
- Stubbed headless smoke checks passed for `dbee.ui.connection_wizard`: exact `postgres://...` seeds reopen in `postgres_form`, env-placeholder passwords round-trip byte-for-byte in wizard state and rendered URLs, wallet alias parsing returns descriptor mappings, and Oracle URL seeds normalize into wallet/custom modes only when the parse is safe.

## Decisions Made

- Oracle wallet submission now defers alias truth to the authoritative ping path: discovered aliases resolve to descriptors when available, and manual alias entry still serializes a best-effort runtime URL instead of being blocked by a local precheck.
- Existing Oracle runtime URLs only reopen into scoped wizard modes when the URL can be losslessly explained; unresolved wallet URLs fall back to raw compatibility rather than pretending the full URL is a custom descriptor.

## Deviations from Plan

None - plan executed as written.

## Issues Encountered

- Direct `require(...)` smoke checks under `nvim --headless -u NONE` fail unless `nui.popup`, `nui.input`, and drawer menu modules are stubbed; verification used lightweight stubs so the serializer and normalizer helpers could be exercised without loading the full UI stack.

## User Setup Required

None.

## Next Phase Readiness

- `08-03` can now open the wizard with raw-record seeds, invoke transient ping against a stable submission object, and route every add/edit save path through the same dispatcher.
- `08-04` has concrete helper exports and state transitions to cover in headless tests for round-trip preservation, wallet alias discovery, and raw compatibility fallback.

---
*Phase: 08-type-aware-connection-wizard*
*Completed: 2026-04-28*
