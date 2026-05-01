# Research Summary: nvim-dbee QoL Improvements

**Domain:** Neovim database explorer plugin -- quality-of-life improvements
**Researched:** 2026-03-05
**Overall confidence:** HIGH

## Executive Summary

All 18 planned QoL improvements integrate cleanly with the existing nvim-dbee architecture. The most significant finding is that **every item can be implemented in Lua only** -- zero Go backend changes are needed. This eliminates the cross-compilation and binary distribution concerns that would normally accompany backend modifications.

The two items initially assessed as requiring Go changes (Explain Plan and Generic Error Diagnostics) were reclassified after detailed analysis. Explain Plan does not fit the existing table-scoped helper system (`GetHelpers(TableOptions)`) because it operates on arbitrary user queries, not table metadata. Instead, a simple Lua-side prefix map keyed by `conn.type` achieves the same result. Generic Error Diagnostics similarly stays in Lua: the error strings returned by each database adapter already contain native location information (PostgreSQL's `LINE N:`, MySQL's `at line N`, Oracle's `at line N`) that can be parsed with per-adapter regex patterns.

The items break into clear tiers by complexity: 7 quick-win notification/formatting changes (L1, single-file), 7 small-effort new actions and keybindings (L2, cross-component), and 4 medium-effort features (drawer filter, explain plan, generic diagnostics, auto-reconnect prompt). All follow established patterns in the codebase.

The existing architecture provides strong extension points: the `get_actions()` pattern on each UI component for adding new keybindable actions, the event bus for async notification callbacks, and the `config.lua` defaults for registering new mappings. No architectural modifications are needed -- only additions within existing boundaries.

## Key Findings

**Stack:** Lua-only development, no Go changes, no binary recompilation
**Architecture:** All changes fit within existing component boundaries (EditorUI, ResultUI, DrawerUI, CallLogUI)
**Critical pitfall:** Drawer search/filter (Item 17) is the only item with meaningful complexity -- it requires recursive tree filtering while preserving NuiTree expansion state

## Implications for Roadmap

Based on research, suggested phase structure:

1. **Notifications and Feedback** (Items 1, 2, 3, 5, 6, 7, 13) - rationale: All L1 single-file changes, highest density of visible improvement per line of code. Fix error handling (13) before success notifications (3).
   - Addresses: Silent failures, missing user feedback
   - Avoids: Cross-component coupling risks

2. **Call Log Enhancements** (Items 4, 8, 14) - rationale: All changes in call_log.lua, natural batch. Build complexity gradually: format (14) -> yank (4) -> re-run (8).
   - Addresses: Call log usability gaps
   - Avoids: Touching multiple components at once

3. **Result and Editor Actions** (Items 9, 11, 15) - rationale: New keybindable actions requiring config.lua additions. Batch config changes.
   - Addresses: Missing export, note cycling, explain plan
   - Avoids: Scope creep into backend

4. **Drawer and Navigation** (Items 10, 12, 17) - rationale: Drawer filter is the largest item, benefits from all prior changes being stable. Jump-between-panes is layout-level.
   - Addresses: Large schema navigation, pane focus management
   - Avoids: Attempting drawer filter before simpler items prove the pattern

5. **Resilience and Diagnostics** (Items 16, 18) - rationale: Most complex event-driven patterns. Auto-reconnect follows cancel-confirm precedent. Generic diagnostics extends existing Oracle-only code.
   - Addresses: Connection resilience, cross-adapter error display
   - Avoids: Shipping resilience features before feedback features are solid

**Phase ordering rationale:**
- L1 items first because they are zero-risk and immediately visible
- Call log batched because all changes are in one file
- Actions phase groups items that all need config.lua mapping additions
- Drawer filter deferred because it is the most complex single item
- Resilience last because it builds on understanding of the event system refined in prior phases

**Research flags for phases:**
- Phase 4: Drawer search needs deeper design for recursive tree filtering with expansion state preservation
- Phase 5: Auto-reconnect prompt needs careful UX design to avoid prompt spam on flaky connections

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Direct codebase analysis, no external dependencies |
| Features | HIGH | All 18 items mapped to specific files and functions |
| Architecture | HIGH | Every item verified against actual source code |
| Pitfalls | MEDIUM | Drawer filter complexity is estimated, not proven |

## Gaps to Address

- Drawer search UX: Should it be incremental (filter-as-you-type) or submit-based? Depends on NuiTree rendering performance with large schemas
- Jump-between-panes: Layout interface may need extension. Current Layout has no `focus_component()` method. May need to expose component winids via state manager instead.
- Explain Plan edge cases: SQL Server uses SET-based explain, not query prefix. May need special handling.
- Auto-reconnect: Need debounce/cooldown to prevent prompt spam when connection is flapping.

---
*Last updated: 2026-03-05*
