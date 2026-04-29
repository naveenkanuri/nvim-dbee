# nvim-dbee Connection UX & Performance Improvements

## What This Is

nvim-dbee is a Neovim database explorer plugin with a Go backend and Lua frontend communicating over RPC. The current milestone focuses on restoring v1.1/v1.2 trust after regressions, then making enterprise-size database browsing practical through schema allowlists and deeper lazy loading.

## Core Value

Every user action should give clear, immediate feedback — no silent failures, no missing affordances, no dead ends.

## Current Milestone: v1.3 Enterprise DB UX + v1.2 Closure

**Goal:** Restore primary v1.1/v1.2 workflows, then make large enterprise schemas fast and focused through schema allowlists, deeper lazy loading, and targeted LSP/drawer polish.

**Target features:**
- High-severity regression closure for wizard visibility, drawer connection-list filtering, and first-run LSP cache migration UX.
- Per-connection schema allowlist plus schemas-only initial load and per-schema lazy table loading.
- LSP/cache residual cleanup, drawer visual polish, and loading timeout/elapsed/cancel affordances.
- Conditional LSP feature gap closure for resolve, hover, code actions, and schema object symbols if mandatory scope finishes with budget headroom.

## Requirements

### Validated

- User can execute queries against multiple database adapters (Oracle, Postgres, MySQL, SQLite, SQL Server, etc.) — existing
- User can view results in a paginated result pane with yank support — existing
- User can manage connections via drawer UI with schema browsing — existing
- User can manage SQL scratchpads (notes) per connection and globally — existing
- User can cancel running queries with `<C-c>` — existing
- User sees cancel-confirm prompt when executing while a query is running — existing
- Query-under-cursor extraction supports PL/SQL blocks and blank-line fallback — existing
- User sees clear notifications, result yank feedback, schema refresh feedback, and actionable warning/error messages — v1.0
- User can use call history with duration/timestamp display, query yank, and re-run on current connection — v1.0
- User can cycle notes, export result sets, and run adapter-aware explain plans — v1.0
- User can copy drawer object names, filter searchable drawer objects, and jump between panes — v1.0
- User sees reconnect recovery prompts and adapter-wide SQL diagnostics for supported execution paths — v1.0
- User can browse structures lazily, open sectioned global/local notes, manage saved connections from a connection-only drawer, add/edit Oracle/Postgres connections through a type-aware wizard, and rely on real-`nui.nvim` drawer performance evidence — v1.1
- User can rely on the built-in dbee LSP perf harness, non-blocking async column completion misses, bounded schema cache indexes/LRU, debounced diagnostics, schema-aware diagnostics, and atomic LSP cache writes — v1.2

### Active

- [ ] DBEE-UX-01: Close high-severity v1.1/v1.2 regressions in the wizard, drawer filter, and LSP cache migration first-run UX
- [ ] DBEE-ARCH-01: Add enterprise schema allowlists and deepen structure lazy loading to schemas-only initial fetch plus per-schema table fetch
- [ ] DBEE-POLISH-01: Clean up LSP residuals, drawer orientation/source-badge noise, and loading timeout/elapsed/cancel UX
- [ ] DBEE-FEAT-02: Conditionally add deferred Phase 12 LSP features if mandatory v1.3 scope lands cleanly

### Out of Scope

- New database adapter support — separate effort, not QoL
- Mobile/remote Neovim support — different problem domain
- Breaking API changes — all improvements must be additive/backward-compatible
- Performance optimization of query execution — separate concern from UX polish
- Multi-connection bulk editing/import/export — v1.1 optimizes single-connection CRUD first
- Result set editing — still excluded due transaction-safety concerns

## Context

- Brownfield codebase: Go backend (`dbee/`) + Lua frontend (`lua/dbee/`)
- Communication via msgpack RPC between Go and Neovim
- Existing codebase map at `.planning/codebase/` (7 documents, 1,774 lines)
- v1.0 shipped all 18 QoL items across Phases 1-5
- Dominant v1.1 pain point: configuring connections currently requires editing `connections.json` directly for real Oracle/Postgres setups
- Existing drawer mixes notes, source controls, saved connections, and database structure; v1.1 intentionally separates notes from drawer navigation
- `FileSource` already implements `create`, `update`, and `delete`; v1.1 hardens it with atomic writes, full-field preservation, and wizard-compatible round-tripping
- v1.2 shipped Phase 10 LSP perf infrastructure and Phase 11 optimization/correctness; Phase 12 feature work is deferred into v1.3 as conditional Phase 16
- v1.3 backlog source of truth is `known-issues.md`; mandatory sequencing is regressions first, architecture second, polish third, conditional LSP features last
- Current v1.3 Codex thread: `019ddb0e-e8d0-7ca1-a4b0-8d4728863630`

## Constraints

- **Backward compatibility**: All changes must be additive — no breaking existing keybindings or API
- **2-pane UI**: Hard constraint at the baseline layout level — editor + result remain the minimum supported workflow. Additional drawer/call_log panes may exist only as additive, layout-owned UI that never becomes mandatory for core usage.
- **RPC awareness**: Minimize RPC round-trips; batch where possible
- **Adapter diversity**: Features touching adapters (explain plan, diagnostics) must handle adapter differences gracefully
- **Locked v1.0 decisions**: Honor Phase 5 decisions D-01..D-29, especially reconnect/diagnostics ownership boundaries
- **Source compatibility**: Existing `connections.json` entries must continue loading; wizard saves must not invalidate EnvSource or MemorySource users

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| All 18 items in scope | User wants complete QoL pass, not cherry-picked subset | Accepted |
| Brownfield approach | Build on existing architecture, no structural changes | Accepted |
| Tier-based phasing | Natural grouping by complexity for roadmap phases | Accepted |
| v1.1 continues phase numbering at Phase 6 | `$gsd-new-milestone` default is continued numbering unless `--reset-phase-numbers` is passed, and old phase directories still exist | Accepted |
| Drawer notes move to picker, not another drawer section | Drawer needs to become a connection-management surface; notes already have a public picker entry point | Accepted |
| FileSource work hardens existing CRUD | `lua/dbee/sources.lua` already has `create/update/delete`; v1.1 should add atomic writes and richer preservation rather than duplicate the contract | Accepted |
| v1.2 LSP feature work deferred to v1.3 | Phase 10/11 perf and correctness were the core v1.2 value; Phase 12 feature gap closure remains additive and conditional | Accepted |
| v1.3 phase order is regressions -> architecture -> polish -> conditional features | Restores broken primary workflows before high-risk schema architecture, then polishes shifted LSP/drawer surfaces before optional feature work | Accepted |
| Phase 13 decision numbering starts at D-198 | Phase 11 ended at D-197 and milestone setup does not consume D-numbers | Accepted |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `$gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `$gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-29 after v1.3 milestone definition*
