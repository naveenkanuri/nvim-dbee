---
phase: 08
slug: type-aware-connection-wizard
status: draft
created: 2026-04-28
---

# Phase 08 — Research

> Focused research for `DCFG-02`: type-aware connection wizard, pre-save driver ping, and atomic FileSource persistence.

## Research Questions

1. What existing drawer/UI seams can Phase 8 reuse without reopening Phase 7 contracts?
2. Why does lossless round-trip require source-local metadata instead of widening runtime `ConnectionParams`?
3. Where should atomic persistence, metadata access, and transient-spec ping live so the phase stays additive?

## Evidence Read

- `.planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md`
- `.planning/PROJECT.md`
- `.planning/ROADMAP.md`
- `.planning/REQUIREMENTS.md`
- `.planning/STATE.md`
- `.planning/phases/04-drawer-navigation/04-CONTEXT.md`
- `.planning/phases/05-resilience-diagnostics/05-CONTEXT.md`
- `.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md`
- `.planning/phases/07-connection-only-drawer/07-CONTEXT.md`
- `lua/dbee/ui/drawer/init.lua`
- `lua/dbee/ui/drawer/menu.lua`
- `lua/dbee/ui/common/floats.lua`
- `lua/dbee/sources.lua`
- `lua/dbee/handler/init.lua`
- `lua/dbee/api/core.lua`
- `lua/dbee/doc.lua`
- `dbee/endpoints.go`
- `dbee/handler/handler.go`
- `dbee/handler/handler_connection_test.go`
- `dbee/core/connection_params.go`
- `ci/headless/check_connection_lifecycle.lua`
- `ci/headless/check_connection_coordination.lua`

## Current-State Findings

### 1. Drawer add/edit is still a raw prompt chain

- `lua/dbee/ui/drawer/init.lua` still uses `prompt_connection_details(...)` for both add and edit.
- That prompt only captures `name`, `type`, and `url`.
- The drawer entry-point routing from Phase 7 already exists (`choose_source`, `open_add_connection`, `open_edit_connection`) and should be reused rather than redesigned.

Conclusion:

- Phase 8 can replace only the prompt body and keep Phase 7 D-67/D-68 intact.

### 2. Existing popup primitives are too small for the locked wizard UX

- `lua/dbee/ui/drawer/menu.lua` provides only single-select and single-input popups.
- `lua/dbee/ui/common/floats.lua` provides a flat key/value prompt and float editor, but not a compound multi-field form with dependent sections, dropdowns, and masked fields.
- The project already depends on `nui.nvim`, so a custom compound modal fits the existing UI stack.

Conclusion:

- D-90 is a real implementation constraint, not just a preference: Phase 8 needs a dedicated wizard module rather than another prompt chain.

### 3. FileSource persistence is currently non-atomic and lossy

- `lua/dbee/sources.lua` does read-modify-write with `io.open(path, "w+")`.
- `update()` only overwrites `name`, `url`, and `type`.
- Unknown fields on the edited record are dropped, and failed writes can clobber the file in place.

Conclusion:

- FileSource hardening must land before final wizard submit wiring, otherwise execute-phase would be forced to save wizard metadata through lossy writes.

### 4. Runtime `ConnectionParams` is intentionally too small for wizard round-trip

- `dbee/core/connection_params.go` still defines runtime params as `{ id, name, type, url }`.
- `connection_get_params()` in Lua and Go only returns that shape.
- Current edit seeding therefore cannot recover wallet path, service alias, descriptor text, or decomposed Postgres form fields.

Conclusion:

- D-97 is mandatory in practice: wizard state has to live in source-local persisted metadata, with additive helper access for edit seeding.

### 5. The current edit path seeds only from runtime params

- `lua/dbee/ui/drawer/convert.lua` and `lua/dbee/ui/drawer/init.lua` use `handler:connection_get_params(conn_id)` for edit defaults.
- That works for raw `name/type/url`, but not for metadata-first wizard reopening.

Conclusion:

- Phase 8 needs an additive raw-record helper surface for edit seeding. Reusing `connection_get_params()` alone would violate D-98.

### 6. The persisted-connection test path already has the right non-mutating behavior

- `dbee/handler/handler.go` `ConnectionTest(connID)` builds a temporary adapter connection and calls `Ping(ctx)` without mutating handler state.
- `dbee/handler/handler_connection_test.go` already proves the path is non-mutating and catches unreachable targets.

Conclusion:

- Phase 8 should add a sibling transient-spec test surface, not rewrite D-82.

### 7. The Phase 7 secondary source-file edit path is already shipped

- `common.float_editor(source_meta.file, ...)` remains wired from the drawer secondary action path.
- Phase 8 does not need to invent a new manual escape hatch; it only needs to preserve and document the existing one.

Conclusion:

- D-106 is low-risk if the wizard wiring stays inside add/edit and leaves the secondary action menu intact.

## Recommended Plan Split

### 08-01 — FileSource Metadata And Atomic Persistence Foundation

Scope:

- atomic same-directory temp-file-plus-rename writes
- unknown-field preservation on edited records
- additive source-local metadata block
- additive raw-record helper for metadata-first edit seeding

Why first:

- It defines the persistence contract the later UI and submit plans depend on.

### 08-02 — Wizard UI Surface And Mode State

Scope:

- compound `nui.nvim` modal
- type/mode flow
- mode-specific field state and local validation
- raw preservation and serializer/parser helpers

Why second:

- It builds the wizard shell and state model without yet risking drawer mutation flow.

### 08-03 — Transient Ping And Drawer Submit Integration

Scope:

- additive transient-spec ping wrapper
- drawer add/edit wiring to the wizard
- metadata-first edit seeding
- test-before-save gating and Phase 7 D-83 integration

Why third:

- It composes the 08-01 persistence helper and 08-02 wizard surface into the final drawer behavior.

### 08-04 — Headless Coverage And CI

Scope:

- wizard flow headless suite
- FileSource atomic/round-trip headless suite
- CI wiring
- Phase 7 regression guards

Why last:

- It proves the phase against the final integrated behavior instead of chasing moving seams.

## Key Research Recommendations

### R1. Keep metadata source-local and additive

- Persist wizard state in the FileSource record under an additive metadata block.
- Add an additive raw-record helper for edit seeding rather than widening runtime params.

### R2. Keep transient ping separate from D-82

- Add a new transient-spec ping surface (`connection_test_spec(...)` or equivalent).
- Leave `connection_test(conn_id)` and its behavior unchanged.

### R3. Keep drawer routing and secondary source editing intact

- Reuse Phase 7 add/edit/source-selection routing.
- Do not hide or replace the source-file editing secondary action.

### R4. Put mode-specific normalization in the wizard layer, not in FileSource

- FileSource should preserve records atomically and semantically.
- The wizard should own mode-to-record serialization, raw text preservation, and lossless parse fallback.

### R5. Use real temp files and real DrawerUI in validation

- FileSource atomic guarantees cannot be proven on pure stubs.
- Wizard flow claims are stronger when tested through real drawer entry points and handler wrappers.

## Risks And Mitigations

| Risk | Why it matters | Mitigation |
|---|---|---|
| Wizard submit lands before FileSource hardening | Would force lossy or non-atomic persistence | Land 08-01 first |
| Edit seeding quietly normalizes legacy URLs/descriptors | Violates D-98 round-trip guarantees | Metadata-first seed, parse only when lossless, otherwise raw fallback |
| Overloading D-82 confuses persisted vs transient test semantics | Risks breaking current drawer test action | Add a sibling transient-spec test surface |
| UI work accidentally hides Phase 7 source-file editing | Regresses D-106 | Keep source-file edit in the secondary action menu and cover it headlessly |

## Research Conclusion

Phase 8 is ready for planning as four sequential plans:

1. FileSource metadata and atomic persistence foundation
2. Wizard UI and mode-state surface
3. Transient ping and drawer submit integration
4. Headless proof and CI

That split honors all locked Phase 4 through Phase 8 decisions, keeps the runtime connection shape untouched, and gives execute-phase a dependency-clean path instead of asking it to invent metadata/persistence seams during submit wiring.
