# Phase 4: Drawer & Navigation - Research

**Researched:** 2026-03-17
**Domain:** Neovim Lua UI (NuiTree filtering, NuiInput live search, buffer-local keymaps, layout interface extension, clipboard)
**Confidence:** HIGH

## Summary

Phase 4 touches three distinct features across four main files: drawer search/filter (DRAW-01), drawer yank of qualified names (CLIP-02), and pane jumping (NAV-02). The drawer search is the most complex feature -- it requires a floating NuiInput prompt with `on_change` callback that rebuilds the drawer's NuiTree with only matching nodes, preserving ancestor containers (connections, schemas) when they have matching children. The existing `menu.input()` function in `drawer/menu.lua` already creates NuiInput floats relative to the drawer window, but it lacks `on_change` support -- the filter prompt needs a new function or modified version that wires `on_change` for live filtering.

The yank feature (CLIP-02) is straightforward: add a `yank_name` action to `DrawerUI:get_actions()` that reads the current node, builds a qualified database object name from its `schema` + `name` fields (or walks up via `node:get_parent_id()` for columns), and writes to both `"` and `+` registers using the same `vim.fn.setreg` pattern established in Phase 2's call log yank. Column nodes lack a `schema` field, so the qualified name must be built by fetching the parent table node from the tree and reading its `schema` + `name`.

The pane jumping feature (NAV-02) requires adding `focus_pane(name)` and `ensure_drawer_visible()` methods to both `DefaultLayout` and `MinimalLayout`, then creating a thin public API function (or set of functions) that delegates to the layout. The keybindings (`<leader>e/r/d/l`) must be registered as buffer-local mappings on ALL dbee pane buffers, which means adding them to drawer, editor, result, and call_log mapping configs.

**Primary recommendation:** Split into two plans: Plan 1 covers CLIP-02 (qualified object-name yank) + NAV-02 (pane jumping) as they are lower-complexity additions to existing patterns. Plan 2 covers DRAW-01 (drawer search/filter) as it requires a new interactive UI component with tree rebuild logic.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- DRAW-01: Live filter mode with `/` trigger key (drawer buffer-local), NOT incremental buffer search
- DRAW-01: Filter prompt is a 1-line floating NuiInput anchored to top of drawer
- DRAW-01: Filter matches table, view, procedure, function node names only
- DRAW-01: Connections and schemas kept visible as ancestor containers when they have matching children
- DRAW-01: Columns are NOT searchable (avoids expanding all lazy children)
- DRAW-01: `<CR>` while filtered always accepts the filter in both prompt modes, captures selected node ID, restores the pre-filter rendered tree, restores expansion, and refocuses node by ID
- DRAW-01: `<Esc>` while filtered clears filter, restores previous cursor/expansion state
- DRAW-01: Empty input restores the pre-filter rendered tree
- DRAW-01: Normal drawer mappings remain unchanged outside filter mode; while the prompt owns focus, `action_1` moves to a non-conflicting alias (`<C-y>`) so `<CR>` stays accept-only
- DRAW-01: Prompt interaction is two-mode: INSERT for typing plus non-printing navigation/toggle keys, INTERACTION entered with `<C-]>`, and `i` returns to typing
- CLIP-02: Qualified name format `schema.table_name` for tables/views/procs, `schema.table.column_name` for columns
- CLIP-02: Target both unnamed (`"`) and system clipboard (`+`) registers
- CLIP-02: Keybinding `yy` in drawer mappings
- CLIP-02: Yankable types: table, view, procedure, function, column
- CLIP-02: Non-yankable nodes: WARN "Nothing to copy"
- CLIP-02: Success notification: `utils.log("info", "Copied: " .. value)`; Phase 4 does not lock any truncation behavior beyond the existing clipboard-unavailable suffix pattern
- NAV-02: Direct pane targeting with `<leader>e` (editor), `<leader>r` (result), `<leader>d` (drawer), `<leader>l` (call log)
- NAV-02: Registered as buffer-local mappings on ALL dbee pane buffers
- NAV-02: Only active when cursor is in a dbee buffer (no global pollution)
- NAV-02: `<leader>d` calls `ensure_drawer_visible()` then `focus_pane("drawer")`
- Layout API: `focus_pane(name) -> boolean` and `ensure_drawer_visible() -> boolean` as optional methods
- Layout API: Feature code checks `if type(layout.focus_pane) == "function" then`
- DefaultLayout: `focus_pane(name)` uses `nvim_set_current_win(self.windows[name])`
- MinimalLayout: `focus_pane("call_log")` returns false, WARNs "Call log pane is not available in this layout"
- Custom layout fallback: WARN notification, never silently no-op

### Claude's Discretion
- Exact NuiInput configuration for filter float (size, position relative to drawer)
- Once `04-02-PLAN.md` exists, DRAW-01 tree rebuild and restore mechanics are no longer discretionary; follow its snapshot-backed searchable-model + session-scoped restore contract
- How to resolve qualified name from node context (walking parent chain vs storing schema on node)
- Whether to add pane-jump mappings to the help node in the drawer
- Case sensitivity for filter matching before `04-02-PLAN.md` exists; after that plan is written, treat case-insensitive matching as locked

### Deferred Ideas (OUT OF SCOPE)
- One-step "focus drawer + start filter" from any pane (global shortcut)
- `list_focusable_panes()` or `get_pane_state()` for richer layout introspection
- Auto-open call_log in MinimalLayout
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| CLIP-02 | User can copy table/column qualified names from drawer to clipboard | Add `yank_name` action to `DrawerUI:get_actions()`. Build qualified name from node's `schema` + `name` fields. For columns, walk up via `tree:get_node(node:get_parent_id())` to get parent table name and schema. Use `vim.fn.setreg('"', value)` + `vim.fn.setreg('+', value)` pattern from Phase 2 call log yank. |
| NAV-02 | User can jump between panes with dedicated keybindings | Add `focus_pane(name)` and `ensure_drawer_visible()` methods to `DefaultLayout` and `MinimalLayout`. Create `dbee.focus_pane(name)` public API that gets layout from `api.current_config().window_layout` and delegates. Register `<leader>e/r/d/l` mappings on all pane buffers. |
| DRAW-01 | User can search/filter database objects in the drawer | `04-02-PLAN.md` is the authoritative implementation contract: use a cache-preflighted searchable model plus rendered restore snapshot, session-scoped prompt callbacks, shared convert helpers, and explicit restore/perf validation. Earlier regenerate + `expansion.set()` sketches in this research doc are superseded. |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| nui.nvim (NuiInput) | installed dependency | Floating input for filter prompt | Already used by `drawer/menu.lua` for input prompts |
| nui.nvim (NuiTree, NuiTree.Node) | installed dependency | Tree rendering and node management | Drawer tree is already a NuiTree; `set_nodes()`, `get_node()`, `get_parent_id()` provide full traversal |
| dbee.utils | internal | `log()`, `trim()` | Phase 1 established notification pattern |
| dbee.ui.common | internal | `configure_buffer_mappings()` | Maps action names to keybindings on buffer |
| dbee.ui.drawer.expansion | internal | `get(tree)` / `set(tree, exp)` | Save/restore tree expansion state during filter |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| vim.fn.setreg | Neovim builtin | Register writes for clipboard | CLIP-02 yank to `"` and `+` registers |
| vim.api.nvim_set_current_win | Neovim builtin | Focus a window by ID | NAV-02 pane jumping |
| vim.api.nvim_win_is_valid | Neovim builtin | Validate window before focusing | NAV-02 safe window access |

## Architecture Patterns

### Modified File Map
```
lua/
  dbee/
    ui/
      drawer/
        init.lua           # MODIFY: add yank_name + filter actions to get_actions(), filter state, snapshot/model helpers
        convert.lua        # MODIFY: add raw_name field for CLIP-02 and shared node/action helpers for filtered parity
        menu.lua           # MODIFY: add/extend menu.filter() with on_change + prompt interaction mappings; do NOT create a parallel prompt in drawer/init.lua
        expansion.lua      # READ-ONLY: referenced for baseline behavior, but DRAW-01 restore is governed by 04-02's snapshot/session contract
    layouts/
      init.lua             # MODIFY: add focus_pane() and ensure_drawer_visible() to both layouts
    config.lua             # MODIFY: add default mappings (yy, /, <leader>e/r/d/l)
    dbee.lua               # ADD: dbee.focus_pane(name) public API function
    api/
      ui.lua               # (optional) could add API entry points for pane focus
```

### Pattern 1: Action Registration (CLIP-02, DRAW-01)
**What:** New actions are functions added to the table returned by `get_actions()`, then mapped via `configure_buffer_mappings()`.
**When to use:** Any new interactive behavior triggered by a keypress in a dbee pane.
**Example (from existing call_log yank):**
```lua
-- In get_actions() return table:
yank_name = function()
  local node = self.tree:get_node() --[[@as DrawerUINode]]
  if not node then return end
  -- ... build qualified name, setreg, utils.log
end,
```

### Pattern 2: Yank to Both Registers (CLIP-02)
**What:** Write value to both unnamed (`"`) and system clipboard (`+`) registers with error handling.
**When to use:** Any yank operation that should populate both registers.
**Established in Phase 2 (call_log.lua lines 242-256):**
```lua
local ok, err = pcall(vim.fn.setreg, '"', value)
if not ok then
  utils.log("error", "Yank failed: " .. tostring(err))
  return
end
pcall(vim.fn.setreg, '+', value)
local ok_get_clip, clip_value = pcall(vim.fn.getreg, '+')
local clip_ok = ok_get_clip and clip_value == value
local msg = "Copied: " .. value
if not clip_ok then
  msg = msg .. " (clipboard unavailable)"
end
utils.log("info", msg)
```

### Pattern 3: Layout Method with Graceful Fallback (NAV-02)
**What:** Optional layout methods that custom layouts may not implement.
**When to use:** Extending the Layout interface without breaking custom layouts.
**Established in dbee.lua toggle_drawer (lines 302-306):**
```lua
local layout = api.current_config().window_layout
if layout and type(layout.toggle_drawer) == "function" then
  layout:toggle_drawer()
end
```

### Pattern 4: NuiInput with on_change (DRAW-01)
**What:** Create a NuiInput that fires a callback on every keystroke for live filtering.
**When to use:** Interactive search/filter prompts.
**NuiInput supports `on_change` natively (verified in source -- uses `nvim_buf_attach` with `on_lines`):**
```lua
local NuiInput = require("nui.input")
local input = NuiInput(popup_options, {
  prompt = "> ",
  default_value = "",
  on_change = function(value)
    -- Called on every keystroke with current input value
    -- NuiInput strips the prompt prefix, so `value` is the raw input text
    self:apply_filter(value)
  end,
  on_submit = function(value)
    -- Called on <CR>
    self:accept_filter()
  end,
  on_close = function()
    -- Called when input is closed without submit (e.g. <Esc> or :q)
    self:cancel_filter()
  end,
})
input:mount()
-- NuiInput automatically enters insert mode on mount
```

**NuiInput lifecycle detail:** On mount, NuiInput enters insert mode automatically (`startinsert!`). On unmount, it calls `stopinsert` and then fires either `on_submit` or `on_close` via `vim.schedule`. The `on_change` callback fires synchronously during insert mode via `nvim_buf_attach` `on_lines` event. This means filter updates happen immediately on keystroke, while submit/close handlers run on the next event loop tick.

### Anti-Patterns to Avoid
- **Global keymaps for pane jumping:** Never use `vim.keymap.set` without `buffer` option -- pane jump keys must be buffer-local to dbee buffers only.
- **Expanding lazy children during filter:** Columns use `lazy_children` functions that trigger database calls. Filter must NOT expand column nodes (which are not searchable anyway per CONTEXT.md).
- **Modifying node IDs during filter:** Filtered tree must preserve node IDs exactly so that `<CR>` accept can refocus by ID after unfiltering.
- **Storing filter state globally:** Filter state (active filter, saved expansion, saved cursor) belongs on the DrawerUI instance, not in module-level variables.
- **Trying to hide NuiTree nodes:** NuiTree has no show/hide API per node. The only way to filter is to regenerate the node list passed to `set_nodes()`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Floating input prompt | Custom window creation | NuiInput with `on_change` callback | NUI handles mount/unmount, cursor management, border styling |
| Tree expansion save/restore | Manual node traversal | `expansion.get(tree)` / `expansion.set(tree, exp)` | Already handles lazy_children loading in second pass |
| Buffer-local keymap registration | Manual `vim.keymap.set` loops | `common.configure_buffer_mappings(bufnr, actions, mappings)` | Handles mode, opts, action resolution from config |
| Node parent traversal | Manual tree walking | `tree:get_node(node:get_parent_id())` | NuiTree.Node has native `get_parent_id()` method |

**Key insight:** The drawer already has all infrastructure for actions (get_actions + configure_buffer_mappings), tree management (NuiTree set_nodes/render), expansion state (expansion.get/set), and floating UI (menu.lua). The filter feature composes these existing pieces with NuiInput's `on_change` callback.

## Common Pitfalls

### Pitfall 1: Column Nodes Lack Schema Field
**What goes wrong:** Column nodes are created by `column_nodes()` in convert.lua with only `id`, `name`, and `type` fields -- no `schema` field.
**Why it happens:** Column nodes are children of table nodes and don't redundantly store schema context.
**How to avoid:** For column yank, walk up the tree: `tree:get_node(node:get_parent_id())` returns the parent table/view node which has both `schema` and `name` fields. Build qualified name as `parent.schema .. "." .. parent.name .. "." .. column_display_name`. Note: column `name` includes the type suffix (" [VARCHAR]") from convert.lua line 19 -- strip the type suffix before building the qualified name.
**Warning signs:** Yank producing `nil.column_name` or `.column_name` for column nodes.

### Pitfall 2: Column Name Includes Type Suffix
**What goes wrong:** Column node `name` field is `"column_name   [VARCHAR]"` (with 3-space gap and type annotation), not the raw column name.
**Why it happens:** `column_nodes()` sets `name = column.name .. "   [" .. column.type .. "]"` at convert.lua line 19.
**How to avoid:** Two options: (a) strip the type suffix from `name` using pattern `node.name:match("^(.-)%s+%[")`, or (b) store the raw column name in a separate field on the node by adding `raw_name = column.name` to column nodes in convert.lua. Option (b) is cleaner and avoids pattern fragility.
**Warning signs:** Yanked value includes `[VARCHAR]` or extra spaces.

### Pitfall 3: Lazy Children Trigger During Filter
> Superseded by the current `04-02-PLAN.md` design. This note describes an earlier regenerate-per-update approach and should NOT be used as the implementation contract for Phase 4.

**What goes wrong:** If filter code calls `expansion.set()` or iterates tree nodes that have `lazy_children` functions, those functions call `connection_get_structure_async` -- causing unwanted network requests.
**Why it happens:** `expansion.set()` loads lazy children on its first pass before expanding (expansion.lua lines 8-18).
**How to avoid (superseded):** Earlier thinking suggested rebuilding filtered nodes by re-running the convert functions. The current plan explicitly replaces that with a cache-preflighted searchable model plus a separate rendered restore snapshot, so the executor should follow `04-02-PLAN.md` instead.
**Warning signs:** Schema load triggered every time user types in filter, or "loading..." nodes appearing during filter.

### Pitfall 4: NuiInput <Esc> Behavior
**What goes wrong:** NuiInput starts in insert mode. Pressing `<Esc>` exits insert mode but does NOT unmount the popup by default. The user is left in a prompt buffer in normal mode.
**Why it happens:** NuiInput uses `prompt_setinterrupt` which fires on `<C-c>` in insert mode, triggering unmount. But `<Esc>` just exits insert mode normally.
**How to avoid:** Explicitly map `<Esc>` on the NuiInput buffer to unmount and restore state: `input:map("n", "<Esc>", function() input:unmount() end, { noremap = true })`. This is consistent with how `menu.lua` handles close mappings. Map in both insert and normal modes to cover both states.
**Warning signs:** Input window stays open after pressing `<Esc>`, user stuck in floating window.

### Pitfall 5: Pane Jump When Window Invalid
**What goes wrong:** `nvim_set_current_win(winid)` errors if the window has been closed (e.g., user manually closed a split).
**Why it happens:** Stored window IDs can become stale.
**How to avoid:** Always check `vim.api.nvim_win_is_valid(winid)` before `nvim_set_current_win()`. Return false from `focus_pane()` if window is invalid.
**Warning signs:** Lua error traceback when pressing pane jump key after closing a window.

### Pitfall 6: Registering Pane Jump Mappings on All Buffers
**What goes wrong:** Pane jump mappings need to be on ALL dbee pane buffers (drawer, editor, result, call_log), but each pane registers its own buffer mappings independently via separate config sections.
**Why it happens:** Each pane has its own `mappings` array in config (`drawer.mappings`, `editor.mappings`, etc.).
**How to avoid:** Add the pane-jump mappings to ALL four mapping arrays in config.lua defaults and expose named `focus_*` actions from each pane's `get_actions()` table. This keeps the help node readable and matches the explicit Phase 4 action-registration contract.
**Warning signs:** Pane jump works from drawer but not from editor, or vice versa.

### Pitfall 7: Filter Node Reconstruction vs. In-Place Pruning
**What goes wrong:** Trying to filter by removing nodes from the already-constructed NuiTree nodes array fails because NuiTree.Node children are stored via internal `_child_ids` after `set_nodes()` is called -- the `__children` field is consumed during initialization.
**Why it happens:** NuiTree `set_nodes()` processes the `__children` array and converts it to `_child_ids` references. After that, you can't simply remove children from the array.
**How to avoid:** Build the filtered node list BEFORE passing to `tree:set_nodes()`. Follow the authoritative `04-02-PLAN.md` snapshot/model contract rather than filtering the output of `convert.handler_nodes()` directly.
**Warning signs:** Filtered tree still shows all nodes, or errors about missing node IDs.

## Code Examples

### Building Qualified Name from Drawer Node (CLIP-02)

```lua
-- Source: Analysis of drawer/convert.lua node structure
---@param tree NuiTree
---@param node DrawerUINode
---@return string|nil qualified_name
local function build_qualified_name(tree, node)
  local yankable_types = {
    table = true, view = true, procedure = true, ["function"] = true, column = true,
  }
  if not yankable_types[node.type] then
    return nil
  end

  if node.type == "column" then
    -- Column: walk up to parent table/view, build schema.table.column
    local parent = tree:get_node(node:get_parent_id())
    if not parent or not parent.schema then
      return nil
    end
    -- raw_name holds the clean column name (without type suffix)
    -- Fallback: parse from display name "col_name   [VARCHAR]"
    local col_name = node.raw_name or node.name:match("^(.-)%s+%[") or node.name
    return parent.schema .. "." .. parent.name .. "." .. col_name
  end

  -- Table/view/procedure/function: schema.name
  if node.schema and node.schema ~= "" then
    return node.schema .. "." .. node.name
  end

  return node.name
end
```

### Filter Node Matching and Pruning (DRAW-01)

```lua
-- Source: Designed based on convert.lua node hierarchy and NuiTree.Node structure
-- The key insight: filter BEFORE passing to tree:set_nodes(), not after.
-- NuiTree.Node uses __children for initial construction, which is consumed by set_nodes().
-- So we filter the NuiTree.Node array while __children is still accessible.

local SEARCHABLE_TYPES = {
  table = true, view = true, procedure = true, ["function"] = true,
}

---@param nodes DrawerUINode[]
---@param pattern string lowercase search pattern
---@return DrawerUINode[]
local function filter_nodes_recursive(nodes, pattern)
  local result = {}
  for _, node in ipairs(nodes) do
    if SEARCHABLE_TYPES[node.type] then
      -- Leaf-level searchable node: include if name matches
      if node.name:lower():find(pattern, 1, true) then
        table.insert(result, node)
      end
    elseif node.__children and #node.__children > 0 then
      -- Container node (source, connection, schema): filter children recursively
      local filtered_children = filter_nodes_recursive(node.__children, pattern)
      if #filtered_children > 0 then
        -- Rebuild container with only matching children
        -- Preserve all container fields (id, name, type, schema, actions, lazy_children)
        local filtered_node = NuiTree.Node(
          { id = node.id, name = node.name, type = node.type, schema = node.schema,
            action_1 = node.action_1, action_2 = node.action_2, action_3 = node.action_3,
            lazy_children = node.lazy_children },
          filtered_children
        )
        table.insert(result, filtered_node)
      end
    end
    -- Non-searchable leaves (add, edit, help, separator, etc): skip during filter
  end
  return result
end
```

**Important implementation note (superseded):** The regenerate-per-update approach above is intentionally NOT the current Phase 4 design. For implementation, follow the cache-preflighted searchable-model approach documented in `04-02-PLAN.md`.

### Layout focus_pane Implementation (NAV-02)

```lua
-- Source: Analysis of layouts/init.lua DefaultLayout and MinimalLayout
-- DefaultLayout:
function layouts.Default:focus_pane(name)
  local winid = self.windows[name]
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  vim.api.nvim_set_current_win(winid)
  return true
end

function layouts.Default:ensure_drawer_visible()
  -- Drawer is always visible in DefaultLayout
  return true
end

-- MinimalLayout:
function layouts.Minimal:focus_pane(name)
  if name == "call_log" then
    return false
  end
  if name == "drawer" then
    if not self.drawer_win or not vim.api.nvim_win_is_valid(self.drawer_win) then
      return false
    end
    vim.api.nvim_set_current_win(self.drawer_win)
    return true
  end
  local winid = self.windows[name]
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  vim.api.nvim_set_current_win(winid)
  return true
end

function layouts.Minimal:ensure_drawer_visible()
  if not self.drawer_win or not vim.api.nvim_win_is_valid(self.drawer_win) then
    self:toggle_drawer()
  end
  return self.drawer_win ~= nil and vim.api.nvim_win_is_valid(self.drawer_win)
end
```

### Pane Jump Mapping Registration (NAV-02)

```lua
-- Source: Phase 4 plan contract
-- Add these keybindings to ALL four pane mapping arrays, but bind them to
-- named pane-local actions so the help node stays readable:
{ key = "<leader>e", mode = "n", action = "focus_editor" },
{ key = "<leader>r", mode = "n", action = "focus_result" },
{ key = "<leader>d", mode = "n", action = "focus_drawer" },
{ key = "<leader>l", mode = "n", action = "focus_call_log" },
```

### NuiInput Filter Prompt Configuration (DRAW-01)

```lua
-- Source: drawer/menu.lua NuiInput pattern + NuiInput source code analysis
-- Position: anchored to top of drawer window, full width, minimal border
local popup_options = {
  relative = {
    type = "win",
    winid = self.winid,
  },
  position = {
    row = 0,  -- top of drawer window
    col = 0,
  },
  size = {
    width = vim.api.nvim_win_get_width(self.winid),
  },
  zindex = 160,  -- same as existing menu.lua popups
  border = {
    style = { "", "", "", "", "", "", "", "" },
    text = {
      top = " Filter ",
      top_align = "left",
    },
  },
}

-- NOTE: Superseded by `04-02-PLAN.md`.
-- Do NOT implement DRAW-01 with `refresh()` + `expansion.set()` restore.
-- The authoritative contract is: cache-preflighted searchable model,
-- rendered restore snapshot, session-scoped prompt callbacks, snapshot-backed
-- replay loaders for materialized branches, and explicit restore/perf gates.

-- Map <Esc> in normal mode too (NuiInput only handles insert-mode interrupt by default)
input:map("n", "<Esc>", function()
  input:unmount()
end, { noremap = true })

input:mount()
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| No drawer search | Live filter with NuiInput on_change | Phase 4 (new) | Users with 100+ tables can find objects quickly |
| Manual `:wincmd` for pane navigation | Dedicated `<leader>` keybindings per pane | Phase 4 (new) | Deterministic pane focus from any dbee buffer |
| No yank from drawer | `yy` yanks qualified name | Phase 4 (new) | Consistent with call log yank pattern from Phase 2 |

## Design Decisions (Claude's Discretion)

### Filter Prompt Configuration
**Decision:** Anchor the NuiInput to row 0 (top of drawer), full drawer width, with "/" prompt prefix.
**Rationale:** Top position is standard for search prompts (vim `/`, telescope, etc.). Full width matches existing menu.lua popup positioning. The "/" prompt prefix reinforces the search metaphor. The NuiInput floats independently of the drawer buffer, so drawer content scrolling does not affect prompt position.

### Case Sensitivity
**Decision:** Case-insensitive matching using `string.lower()` on both filter text and node names.
**Rationale:** Database object names are often uppercase or mixed-case. Case-insensitive search is the overwhelmingly common default in search UIs (telescope, fzf, etc.). Users who know the exact case can still benefit.

### Tree Rebuild Strategy for Filter
**Decision:** Superseded by `04-02-PLAN.md`.
**Rationale:** The authoritative DRAW-01 contract is now the cache-preflighted searchable-model + rendered-restore-snapshot design with shared convert helpers and session-scoped callback handling. Do not revert to a plain `refresh()`-driven regenerate flow.

### Expansion State During Filter
**Decision:** Superseded by `04-02-PLAN.md`.
**Rationale:** The authoritative restore path now uses a rendered restore snapshot, ancestor-first replay of saved expansion ids, and snapshot-backed lazy replay for materialized branches. Plain `expansion.set()` restore is no longer the Phase 4 contract.

### Qualified Name Resolution for Columns
**Decision:** Walk up the tree via `node:get_parent_id()` to find the parent table node, then use its `schema` and `name` fields. Also add `raw_name` field to column nodes in convert.lua to store the clean column name (without "   [TYPE]" suffix).
**Rationale:** Column nodes already store their parent reference via NuiTree's parent tracking. Adding `raw_name` is a one-line change in `column_nodes()` that avoids fragile string parsing. Walking up one level (column -> table) is cheap and reliable.

### Pane Jump Help Node
**Decision:** Yes, add pane-jump mappings to the drawer help node for discoverability.
**Rationale:** The help node already iterates over `self.mappings` and displays them. Since pane-jump mappings will be in the drawer mappings config, they will automatically appear in the help node without extra work. However, the inline function actions won't display a readable action name -- so the help node will show the function reference. Consider using named action strings that resolve to the function.

## Validation Architecture

> Superseded by the current `04-VALIDATION.md` + `04-02-PLAN.md` contract. The notes below describe an earlier manual-first validation model and are retained only as historical research context. Do NOT use them for execution, verification, or sign-off now that the Phase 4 validation docs exist.

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Manual Neovim testing (no Lua test framework in project) |
| Config file | N/A |
| Quick run command | Open Neovim, `:lua require("dbee").open()`, test feature |
| Full suite command | Manual walkthrough of all test scenarios below |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CLIP-02 | `yy` on table node yanks `schema.table_name` | manual-only | Navigate to table, `yy`, `:echo @"` | N/A |
| CLIP-02 | `yy` on column node yanks `schema.table.column_name` | manual-only | Expand table, navigate to column, `yy`, `:echo @"` | N/A |
| CLIP-02 | `yy` on connection node shows "Nothing to copy" | manual-only | Navigate to connection, `yy`, verify WARN | N/A |
| CLIP-02 | System clipboard receives same value | manual-only | After yank, `:echo @+` matches `:echo @"` | N/A |
| NAV-02 | `<leader>e` from drawer focuses editor | manual-only | Focus drawer, `<leader>e`, verify cursor in editor | N/A |
| NAV-02 | `<leader>d` from editor opens+focuses drawer in MinimalLayout | manual-only | Use MinimalLayout, `<leader>d`, verify drawer appears | N/A |
| NAV-02 | `<leader>l` in MinimalLayout shows WARN | manual-only | Use MinimalLayout, `<leader>l`, verify notification | N/A |
| NAV-02 | Pane jump on custom layout without focus_pane shows WARN | manual-only | Use custom layout, attempt jump, verify notification | N/A |
| DRAW-01 | `/` opens filter prompt at top of drawer | manual-only | In drawer, press `/`, verify floating input appears | N/A |
| DRAW-01 | Typing filters tree to matching searchable objects only | manual-only | Type partial name, verify non-matching nodes hidden | N/A |
| DRAW-01 | Ancestor containers (connection, schema) remain visible | manual-only | Filter, verify connection/schema nodes still shown | N/A |
| DRAW-01 | `<CR>` clears filter and refocuses selected node | manual-only | Filter, select match, `<CR>`, verify full tree with cursor on node | N/A |
| DRAW-01 | `<Esc>` restores pre-filter expansion state | manual-only | Expand some, filter, `<Esc>`, verify expansion restored | N/A |
| DRAW-01 | Empty input shows full tree | manual-only | Type, then delete all, verify full tree | N/A |

**Justification for manual-only:** All features involve Neovim UI state (window focus, floating windows, tree rendering, cursor position) that require a running Neovim instance. The project has no Lua test framework -- only Go tests for the backend. These are pure UI integration tests.

### Sampling Rate
- **Per task commit:** Manual smoke test of the specific feature
- **Per wave merge:** Full walkthrough of all scenarios above
- **Phase gate:** Complete manual test matrix before verify

### Wave 0 Gaps
None -- no automated test infrastructure applicable to Lua UI features in this project.

## Open Questions

1. **Filter performance with very large schemas (1000+ tables)**
   - Superseded by `04-02-PLAN.md`.
   - The authoritative DRAW-01 contract forbids per-keystroke full rebuilds through `convert.*` / `refresh()`, requires raw hot-path budgets before any debounce polish, and defines the locked corpus/query cohort plus restore/soak gates.

2. **Column nodes in filtered view**
   - Resolved by `04-02-PLAN.md`: columns are NOT searchable, but matched tables/views remain expandable while filtered.

3. **Help node display for inline function actions**
   - Resolved by `04-01-PLAN.md`: pane-jump mappings use named `focus_*` actions rather than inline functions so the help node stays readable.

## Sources

### Primary (HIGH confidence)
- NuiInput source code at `~/.local/share/nvim/lazy/nui.nvim/lua/nui/input/init.lua`: `on_change` callback confirmed (line 27 type def, lines 82-93 implementation via `nvim_buf_attach` + `on_lines`). Mount auto-enters insert mode (line 127 `startinsert!`). Unmount fires `on_submit` or `on_close` via `vim.schedule` (lines 148-167).
- NuiTree source code at `~/.local/share/nvim/lazy/nui.nvim/lua/nui/tree/init.lua`: `Node:get_parent_id()` at line 97-99. `set_nodes()` consumes `__children` and converts to `_child_ids` at lines 309-333. No show/hide API per node.
- `drawer/init.lua` lines 583-608: `refresh()` method pattern (set_nodes + expansion.get/set + render)
- `drawer/convert.lua` lines 10-26: column_nodes() creates nodes with `id`, `name`, `type` only -- no `schema` field. Name includes type suffix at line 19.
- `drawer/convert.lua` lines 48-56: table/view/procedure/function nodes get `schema = struct.schema` field.
- `drawer/menu.lua` lines 88-151: existing NuiInput usage pattern for drawer floats (popup_options, position relative to drawer window)
- `call_log.lua` lines 232-256: established yank pattern (setreg + pcall + round-trip verify)
- `layouts/init.lua`: DefaultLayout `self.windows` table at line 135-166, MinimalLayout `self.drawer_win` at line 202-207, `toggle_drawer()` at lines 361-379
- `config.lua` lines 79-100: drawer default mappings pattern
- `dbee.lua` lines 302-306: `toggle_drawer()` pattern for optional layout methods with `type()` check

### Secondary (MEDIUM confidence)
- [NUI Input documentation](https://github.com/MunifTanjim/nui.nvim/wiki/nui.input): on_change, on_submit, on_close API docs
- [NUI Tree documentation](https://github.com/MunifTanjim/nui.nvim/tree/main/lua/nui/input): set_nodes, get_node, get_nodes API

### Tertiary (LOW confidence)
- None -- all findings verified against source code

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all libraries already in use, no new dependencies
- Architecture: HIGH -- all patterns directly observed in existing codebase (refresh, get_actions, configure_buffer_mappings, expansion state)
- Pitfalls: HIGH -- identified from concrete code analysis (column node structure, lazy_children triggers, NuiTree __children consumption, NuiInput mode behavior)
- Filter design: HIGH -- tree rebuild strategy grounded in NuiTree internals (verified `__children` -> `_child_ids` conversion)

**Research date:** 2026-03-17
**Valid until:** 2026-04-17 (stable domain -- NUI API and Neovim API are mature)
