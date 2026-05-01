# Phase 15 — Connection Folder Grouping (DBeaver-Style)

**Milestone:** v1.3 LIVING (final scoped phase)
**Status:** PLAN final (rev 15 — clean rewrite + r7..r15 precision fixes inline)
**Author:** autopilot session, 2026-05-01

This document is the SINGLE SOURCE OF TRUTH. No "resolutions" sections — every contract here is the final intent. All historical revision drift has been removed. The plan-gate trail (r1=6, r2=6, r3=6, r4=4, r5=6) findings are folded into Layer contracts directly.

## Goal

Allow users to group connections inside each Source under named folders. Folders render in the drawer between source root and individual connections. Persisted per-source as a sidecar JSON file alongside `connections.json` — never mixing into the connection records.

## Locked decisions (do not re-litigate)

1. **Per-source scope.** Each Source owns its own folder set. No cross-source / global folders.
2. **Sidecar persistence.** For `FileSource(path)` at e.g. `~/.local/share/nvim/dbee/persistence.json`, folders live in derived path `<base>.folders.json`. `connections.json` schema NOT extended.
3. **Flat hierarchy in v1.** No nested folders. Future extension possible.
4. **Stable connection IDs.** Folder records reference connection IDs; IDs survive across runs (`sources.lua:255`).
5. **Ungrouped connections render at source root.** Migration is zero-touch.
6. **Drawer-level CRUD only.** No `:Dbee folder_*` commands. NO new node-action slots (action_1..3 only).
7. **Atomic disk writes** via `write_records_atomically()` (`sources.lua:86-119`).
8. **Backward-compat:** Sources without folder methods silently degrade — drawer renders connections directly under source root, folder actions warn-no-op.
9. **Corrupt sidecar fail-safe.** JSON decode failure → `_folders_load_state = "load_failed"`. ALL mutations refuse to write. User must repair manually.

## Architecture

### Sidecar file format (`<source>.folders.json`)

```json
[
  { "id": "folder_<random>", "name": "Production", "connection_ids": ["pg_main", "ora_dwh"] },
  { "id": "folder_<random>", "name": "Staging",    "connection_ids": ["pg_stg"] }
]
```

- `id`: stable folder ID (auto-generated `folder_<utils.random_string()>`).
- `name`: user-visible label. Unique within source case-insensitively.
- `connection_ids`: ordered list. **Order = drawer render order within folder.**
- A connection ID may appear in AT MOST ONE folder. Ungrouped = absent from all folders.

### Sidecar path derivation (`FileSource:folders_path()`)

- If `self.path` ends in `.folders.json` → append `.folders.json` again (collision-safe).
- Else if ends in `.json` → replace suffix → `<base>.folders.json`.
- Else → append `.folders.json`.

---

### Layer 1: Source contract additions (`lua/dbee/sources.lua`)

Optional Source methods (default-absent). Detect via `type(source.supports_folders) == "function" and source:supports_folders()`.

- `supports_folders() -> boolean` — capability flag. FileSource overrides to true; default Source contract does not implement.
- `load_folders() -> Folder[]` — returns folder list or `{}`. Re-callable; cached after first load.
- `add_folder(name) -> folder_id` — generates id, validates uniqueness, atomic-write, returns id.
- `rename_folder(folder_id, new_name)` — validates new_name uniqueness vs OTHER folders, atomic-write.
- `remove_folder(folder_id)` — drops folder, atomic-write. Members become ungrouped.
- `move_connection(conn_id, target_folder_id_or_nil)` — single-pass remove-then-insert. nil = ungrouped. Idempotent.
- `reload_folders()` — invalidates cache; next `load_folders()` re-reads disk. Called by Handler on source reload.

---

### Layer 2: FileSource implementation (`lua/dbee/sources.lua`)

State fields (per FileSource instance):
- `_folders_path` (lazy)
- `_folders_cache : Folder[]` (lazy)
- `_folders_load_state : "unloaded" | "loaded_ok" | "load_failed"`
- `_folders_load_error : string|nil`

Methods:

- `folders_path()` — see derivation above.
- `_ensure_folders_loaded()`:
  - state == "loaded_ok" → return ok.
  - state == "load_failed" → return failure (no auto-retry; caller must call `reload_folders()`).
  - state == "unloaded" → read file. Missing → cache = {}, state = loaded_ok.
    - JSON decode error → state = load_failed, error recorded, cache = empty (read-only display fallback).
    - **Malformed-but-decodable shape (SHARED CONTRACT — same gates as delete pre-read):**
      - `type(decoded) ~= "table"` OR `not vim.islist(decoded)` → state = load_failed.
      - For each entry: `type(folder) ~= "table"` OR `type(folder.connection_ids) ~= "table"` OR `not vim.islist(folder.connection_ids)` → state = load_failed.
    - Otherwise normalize via `_normalize_folders` and set loaded_ok.
  - **Single source of truth:** the malformed-shape rules above are the SAME rules used by FileSource:delete pre-read. No divergence between code paths.
- `_normalize_folders(raw, conns)`:
  - **PRECONDITION:** runs ONLY AFTER `_ensure_folders_loaded()` shared shape validation has passed (state == loaded_ok). Non-table top-level OR non-table folder entries OR non-list connection_ids would have already set state = load_failed and prevented this call.
  - For each folder (all guaranteed valid table shape with list connection_ids): ensure id non-empty (assign new + warn if missing), name non-empty.
  - Dedupe `connection_ids` across ALL folders: keep first occurrence, warn each duplicate.
  - Drop `connection_ids` whose conn is not in `conns` (warn). Membership-only — DOES NOT touch disk.
  - All normalization is in-memory; first mutation persists the cleaned form.
- `load_folders()`:
  - Calls `_ensure_folders_loaded()`. Returns cache. If state == load_failed, returns empty + log warn each call (non-throwing display fallback).
- **`_require_folders_writeable()`** — single write gate used by ALL mutation methods:
  ```lua
  function FileSource:_require_folders_writeable()
    self:_ensure_folders_loaded()  -- may transition unloaded → loaded_ok OR load_failed
    if self._folders_load_state == "load_failed" then
      error({ message = "folders sidecar is corrupt; refusing to overwrite", cache_corrupt = true })
    end
    -- state is now loaded_ok; safe to mutate
  end
  ```
  Single funnel — no path can write a corrupt sidecar. Every folder mutation method's first line is `self:_require_folders_writeable()`.
- `add_folder(name)`:
  - `self:_require_folders_writeable()` (single gate — see definition above; throws cache_corrupt error if state ends load_failed).
  - Validate name non-empty + unique case-insensitive vs current cache.
  - Generate `folder_<utils.random_string()>` id.
  - Mutate cache. `write_records_atomically(folders_path(), cache)`. Return id.
- `rename_folder(id, new_name)`:
  - `self:_require_folders_writeable()`. Validate id exists, new_name non-empty, unique vs OTHER folders case-insensitive (allow case-only rename of self). Mutate. Atomic write.
- `remove_folder(id)`:
  - `self:_require_folders_writeable()`. Validate id exists. Drop folder. Atomic write. Members become ungrouped naturally.
- `move_connection(conn_id, target_folder_id_or_nil)`:
  - `self:_require_folders_writeable()`.
  - If target_folder_id ~= nil → validate exists.
  - Single-pass: remove conn_id from any current folder; if target ~= nil → append to target.connection_ids.
  - Idempotent: if final state matches initial, no disk write — just return ok.
  - Atomic write on actual change.
- `delete(conn_id)` (existing FileSource:delete at `sources.lua:266`):
  - **EXACT algorithm (one path, no alternatives):**
  ```lua
  function FileSource:delete(conn_id)
    -- Step 0: if folder cache is ALREADY load_failed (from a prior load attempt),
    -- force prune-skip regardless of what raw pre-read finds. fail-safe enforced
    -- before any sidecar I/O.
    local prior_load_failed = (self._folders_load_state == "load_failed")

    -- Step 1: non-throwing raw sidecar pre-read (pcall + JSON decode only, no normalize).
    -- This avoids the chicken-and-egg with _normalize_folders requiring conns from self:load()
    -- which would post-delete miss the conn we're about to remove.
    local pre_read_ok = false
    local was_member = false
    local raw_folders = nil
    local ok, content = pcall(function()
      local fd = io.open(self:folders_path(), "r")
      if not fd then return nil end
      local s = fd:read("*a")
      fd:close()
      return s
    end)
    if ok and content and content ~= "" then
      local decode_ok, decoded = pcall(vim.json.decode, content)
      if decode_ok and type(decoded) == "table" then
        raw_folders = decoded
        pre_read_ok = true
        -- Defensive: malformed-but-decodable JSON (e.g., [1] or [{conn_ids: "bad"}])
        -- must NOT throw. Type-guard every iteration.
        for _, folder in ipairs(raw_folders) do
          if type(folder) == "table" and type(folder.connection_ids) == "table" then
            for _, cid in ipairs(folder.connection_ids) do
              if cid == conn_id then was_member = true; break end
            end
          end
          if was_member then break end
        end
      else
        -- Corrupt sidecar (decode failed) — set load_failed state so future load_folders surfaces it
        self._folders_load_state = "load_failed"
        self._folders_load_error = "JSON decode failed during delete pre-read"
        utils.log("warn", "folders sidecar corrupt (decode failed); conn delete proceeds, folder prune skipped")
      end
    end

    -- Track malformed top-level shape AND malformed-but-decodable folder entries
    -- so the sentinel "load_failed + warn" contract holds for ALL non-array-of-arrays cases.
    if pre_read_ok then
      local saw_malformed = false
      -- Sidecar contract — JSON shape rules:
      --   * Missing file       → valid empty (handled at file-open layer above)
      --   * JSON `[]`          → valid empty list (vim.islist returns true)
      --   * JSON `{}`          → INVALID: vim.json.decode returns vim.empty_dict()
      --                         which fails vim.islist → load_failed + warn
      --   * JSON `{"k": ...}`  → INVALID: keyed object → fails vim.islist
      --   * JSON `[1]`         → INVALID: non-table folder entry
      --   * JSON `[{"connection_ids": "bad"}]` → INVALID: non-list connection_ids
      if type(raw_folders) ~= "table" or not vim.islist(raw_folders) then
        saw_malformed = true
      else
        for _, folder in ipairs(raw_folders) do
          if type(folder) ~= "table"
              or type(folder.connection_ids) ~= "table"
              or not vim.islist(folder.connection_ids) then
            saw_malformed = true
            break
          end
        end
      end
      if saw_malformed then
        self._folders_load_state = "load_failed"
        self._folders_load_error = "malformed folder entries during delete pre-read"
        utils.log("warn", "folders sidecar has malformed entries; conn delete proceeds, folder prune SKIPPED")
        -- Fail-safe: load_failed LOCKS sidecar writes. Set pre_read_ok = false so
        -- Step 3 prune is fully skipped (no partial-write on corrupt sidecar).
        pre_read_ok = false
      end
    end

    -- Step 2: Existing connection delete flow runs unchanged.
    -- (call into the existing delete logic that writes connections.json)

    -- Step 3: prune sidecar IFF pre_read_ok AND was_member AND NOT prior_load_failed.
    -- prior_load_failed locks ALL writes regardless of fresh pre-read result.
    if pre_read_ok and was_member and not prior_load_failed then
      -- Mutate raw_folders: remove conn_id from any folder. Type-guard each iter
      -- (some folder entries may have been malformed and skipped in scan; honor same skip here).
      for _, folder in ipairs(raw_folders) do
        if type(folder) == "table" and type(folder.connection_ids) == "table" then
          for i = #folder.connection_ids, 1, -1 do
            if folder.connection_ids[i] == conn_id then
              table.remove(folder.connection_ids, i)
            end
          end
        end
      end
      local write_ok, write_err = pcall(write_records_atomically, self:folders_path(), raw_folders)
      if not write_ok then
        utils.log("error", "folder prune write failed: " .. tostring(write_err))
        -- conn deletion stands; next mutation re-normalizes via cache reload
      else
        -- Update in-memory cache to match disk
        if self._folders_load_state == "loaded_ok" then
          for _, folder in ipairs(self._folders_cache) do
            for i = #folder.connection_ids, 1, -1 do
              if folder.connection_ids[i] == conn_id then
                table.remove(folder.connection_ids, i)
              end
            end
          end
        end
      end
    end
  end
  ```
  - Corrupt sidecar (decode fail) → state = load_failed, log warn, conn deletion proceeds, folder prune skipped. NEVER blocks connection deletion.
  - Sentinel `FOLDER15_DELETE_CONN_PRUNES_FOLDER_MEMBERSHIP_OK` covers loaded-cache case AND cold-cache case (both verified end-to-end via fixtures).
  - New sentinel `FOLDER15_DELETE_CONN_CORRUPT_SIDECAR_NO_BLOCK` asserts: ALL of (a) JSON decode failure, (b) JSON `{}` (empty object — fails vim.islist), (c) JSON `{"k": value}` (keyed-object top-level), (d) JSON `[1]` (non-table folder entry), (e) JSON `[{"connection_ids": "bad"}]` (non-list connection_ids) → conn delete still succeeds + warn logged + state set to load_failed.

  Valid shapes that MUST NOT trigger load_failed: missing file, JSON `[]` (empty list).

  **Additional sentinel coverage**: `FOLDER15_DELETE_CONN_CORRUPT_SIDECAR_NO_BLOCK` ALSO covers the "already load_failed before delete" case — conn deletion proceeds + Step 3 prune SKIPPED.
- `reload_folders()`:
  - Reset state to "unloaded", clear cache, clear error. Next read re-loads.

---

### Layer 3: Handler facade (`lua/dbee/handler/init.lua`)

```lua
function Handler:source_get_folders(source_id)
  local source = self.sources[source_id]  -- direct access (matches existing pattern at handler/init.lua:1846, 2044, 2094, 2138, 2216, 2247)
  if not source or type(source.supports_folders) ~= "function" or not source:supports_folders() then
    return {}
  end
  local ok, folders = pcall(source.load_folders, source)
  if not ok then
    utils.log("warn", "source_get_folders failed: " .. tostring(folders))
    return {}
  end
  return folders or {}
end

function Handler:_require_folder_capable_source(source_id)
  local source = self.sources[source_id] or error("unknown source: " .. tostring(source_id))
  if type(source.supports_folders) ~= "function" or not source:supports_folders() then
    error("source does not support folders: " .. tostring(source_id))
  end
  return source
end

function Handler:source_add_folder(source_id, name)
  local source = self:_require_folder_capable_source(source_id)
  local id = source:add_folder(name)
  self:_emit_connection_invalidated("folder_mutation", { source_id = source_id, folder_id = id, op = "add" })
  return id
end

function Handler:source_rename_folder(source_id, folder_id, new_name)
  local source = self:_require_folder_capable_source(source_id)
  source:rename_folder(folder_id, new_name)
  self:_emit_connection_invalidated("folder_mutation", { source_id = source_id, folder_id = folder_id, op = "rename" })
end

function Handler:source_remove_folder(source_id, folder_id)
  local source = self:_require_folder_capable_source(source_id)
  source:remove_folder(folder_id)
  self:_emit_connection_invalidated("folder_mutation", { source_id = source_id, folder_id = folder_id, op = "remove" })
end

function Handler:source_move_connection(source_id, conn_id, target_folder_id)
  local source = self:_require_folder_capable_source(source_id)
  source:move_connection(conn_id, target_folder_id)
  self:_emit_connection_invalidated("folder_mutation", { source_id = source_id, conn_id = conn_id, target_folder_id = target_folder_id, op = "move" })
end
```

Cache invalidation on source reload — wherever Handler emits `connection_invalidated("source_reload", ...)` (`init.lua:2021`), ALSO call `source:reload_folders()` if folder-capable.

---

### Layer 4: Drawer rendering (`lua/dbee/ui/drawer/convert.lua`)

Add helper:
```lua
function M.folder_node_id(parent_id, source_id, folder_id)
  return parent_id .. ID_SEP .. encode_node_segment({ "folder", source_id, folder_id })
end
```

Modify `handler_real_nodes()` (line 352):

```lua
local function handler_real_nodes(handler, result, structure_cache, opts)
  local nodes = {}
  local sources = handler:get_sources()
  local show_source_badge = #sources > 1
  local root_id = "__handler_root__"

  for _, source in ipairs(sources) do
    local source_id = source:name()
    local source_meta = build_source_meta(source, source_id)
    local folders = handler:source_get_folders(source_id)
    local conns = handler:source_get_connections(source_id)

    -- O(N) index
    local conn_by_id = {}
    for _, c in ipairs(conns) do conn_by_id[c.id] = c end

    local in_folder = {}

    -- Folders in folders[] insertion order
    for _, folder in ipairs(folders) do
      local folder_id_full = M.folder_node_id(root_id, source_id, folder.id)
      local children = {}
      -- Iterate folder.connection_ids in ORDER (drawer render order within folder)
      for _, conn_id in ipairs(folder.connection_ids or {}) do
        local conn = conn_by_id[conn_id]
        if conn then
          in_folder[conn_id] = true
          children[#children + 1] = build_connection_node(handler, conn, result, structure_cache, opts, source_meta, show_source_badge)
        end
      end
      nodes[#nodes + 1] = build_folder_node(folder, source_meta, folder_id_full, children, handler)
    end

    -- Ungrouped in source_get_connections() order
    for _, conn in ipairs(conns) do
      if not in_folder[conn.id] then
        nodes[#nodes + 1] = build_connection_node(handler, conn, result, structure_cache, opts, source_meta, show_source_badge)
      end
    end
  end

  return nodes
end
```

`build_folder_node(folder, source_meta, folder_id_full, children, handler)`:
- `id = folder_id_full`
- `name = "📁 " .. folder.name`
- `type = "folder"`
- `raw_name = folder.name`
- `folder_id = folder.id`
- `source_meta = source_meta`
- `search_text = folder.name`
- `lazy_children = function() return children end`
- `action_1 = function(cb) cb() end` — no-op (drawer expand_node handles expansion)
- decorate via `M.decorate_folder_node(node, handler, source_meta, folder.id)` (action_2 = rename, action_3 = delete).

`build_connection_node` is the existing inline node creation at `convert.lua:365-377` extracted into a reusable helper.

`decorate_folder_node` — assigns PLAIN FUNCTIONS matching `function(cb, select_fn, input_fn)` contract. `perform_node_action` (`init.lua:2856`) requires plain functions; tables silently no-op.

```lua
function M.decorate_folder_node(node, handler, source_meta, folder_id)
  node.action_2 = function(cb, _, input)
    input({
      title = "Rename folder: " .. tostring(node.raw_name or ""),
      default = node.raw_name or "",
      on_confirm = function(new_name)
        if new_name and new_name ~= "" then
          local ok, err = pcall(handler.source_rename_folder, handler, source_meta.id, folder_id, new_name)
          if not ok then utils.log("error", "rename folder: " .. tostring(err)) end
        end
        cb()
      end,
    })
  end

  node.action_3 = function(cb, select)
    local DELETE_LABEL = "Delete (members ungrouped)"
    select({
      title = "Delete folder: " .. tostring(node.raw_name or ""),
      items = { DELETE_LABEL, "Cancel" },  -- menu.select is STRING-ONLY (menu.lua:6)
      on_confirm = function(selection)
        if selection == DELETE_LABEL then
          local ok, err = pcall(handler.source_remove_folder, handler, source_meta.id, folder_id)
          if not ok then utils.log("error", "delete folder: " .. tostring(err)) end
        end
        cb()
      end,
    })
  end
end
```

---

### Layer 5: Drawer-level actions (`lua/dbee/ui/drawer/init.lua`)

Add private helper at the top of the actions block. Bind `local handler = self.handler` early in `DrawerUI:get_actions()` so all nested callbacks see it:

```lua
function DrawerUI:get_actions()
  local handler = self.handler  -- bind once for all action closures

  local function _guarded_folder_mutation(label, fn, on_done)
    local ok, err = pcall(fn)
    if not ok then
      utils.log("error", label .. ": " .. tostring(err))
    end
    if on_done then on_done() end
  end

  -- ... rest of actions
end
```

Add 4 entries to `DrawerUI:get_actions()` return table (mirrors `add_connection` at `init.lua:3023`). All four use `_guarded_folder_mutation`.

`add_folder` — pick folder-capable source via menu (auto-pick if 1; warn-noop if 0), prompt name via menu.input. On confirm:
```lua
_guarded_folder_mutation("add folder", function()
  handler:source_add_folder(source_id, name)
end, on_done)
```

`rename_folder` — current node must be `type == "folder"`. If not → `utils.log("warn", "Select a folder row to rename")`, on_done(), return. Otherwise reuse `decorate_folder_node` action_2 logic via menu.input + `_guarded_folder_mutation`.

`delete_folder` — current node must be `type == "folder"`. Same warn-then-return on mismatch. Reuse decorate's action_3 logic.

`move_connection_to_folder` — resolve current node via `resolve_connection_ancestor()` (line 2973). If no conn_id → warn-noop. Then resolve full context:

```lua
local conn_id = resolve_connection_ancestor(self.tree, current_node)
if not conn_id then utils.log("warn", "Select a connection row to move"); return end

local source_meta, conn = resolve_connection_source_meta(self.handler, conn_id)
if not source_meta or not conn then utils.log("warn", "Connection source not found"); return end

local source_id = source_meta.id
local source = self.handler.sources[source_id]
if not source or type(source.supports_folders) ~= "function" or not source:supports_folders() then
  utils.log("warn", "Source does not support folders")
  return
end

local folders = self.handler:source_get_folders(source_id)
```

`resolve_connection_source_meta` is the existing helper used by `add_connection` action (mirrors that pattern).

Build picker — STRING-ONLY items + lookup map (menu.select is string-based per `menu.lua:6`):

```lua
local UNGROUPED_LABEL = "(ungrouped)"
local NEW_FOLDER_LABEL = "+ New folder…"
local items = { UNGROUPED_LABEL }
local label_to_target = { [UNGROUPED_LABEL] = nil }
local used = { [UNGROUPED_LABEL] = true }

-- Deterministic unique-label generator. folder_id has shape "folder_<random>" so
-- :sub(1,6) is always "folder" — must use TAIL :sub(-N).
local function unique_label(used_set, base, folder_id)
  if not used_set[base] then return base end
  local tail_len = 6
  while true do
    local candidate = base .. " [" .. folder_id:sub(-tail_len) .. "]"
    if not used_set[candidate] then return candidate end
    if tail_len >= #folder_id then
      -- Exhausted ID; append deterministic counter suffix (loop until unused)
      local counter = 1
      while used_set[candidate .. "#" .. tostring(counter)] do counter = counter + 1 end
      return candidate .. "#" .. tostring(counter)
    end
    tail_len = tail_len + 4
  end
end

for _, folder in ipairs(folders) do
  local base = "📁 " .. folder.name
  local label = unique_label(used, base, folder.id)
  used[label] = true
  items[#items+1] = label
  label_to_target[label] = folder.id
end
items[#items+1] = NEW_FOLDER_LABEL
used[NEW_FOLDER_LABEL] = true
label_to_target[NEW_FOLDER_LABEL] = "__new__"
```

On confirm `selection`:

```lua
local target = label_to_target[selection]
if target == "__new__" then
  -- nested input: prompt new folder name, then add+move atomically (caller pcall)
  input({
    title = "New folder name", default = "",
    on_confirm = function(new_name)
      if new_name and new_name ~= "" then
        _guarded_folder_mutation("create+move", function()
          local id = handler:source_add_folder(source_id, new_name)
          handler:source_move_connection(source_id, conn_id, id)
        end, on_done)
      else
        on_done()
      end
    end,
  })
else
  _guarded_folder_mutation("move connection", function()
    handler:source_move_connection(source_id, conn_id, target)
  end, on_done)
end
```

If add succeeds but move fails, empty folder remains (acceptable; user can delete or retry move).

---

### Layer 6: Top-level dbee API + actions menu (`lua/dbee.lua`)

Verified API surface (do NOT use `api.core.*` references — those are stale from earlier revisions):
- `dbee.is_open()` (lua/dbee.lua:301)
- `dbee.open()` (lua/dbee.lua:284) — bootstraps as needed
- `dbee.focus_pane("drawer")` (lua/dbee.lua:319)
- `api.ui.drawer_do_action(action)` (lua/dbee/api/ui.lua:184)

Add closed-drawer-safe helper. **Whole body in pcall** so dbee.is_open / open / focus_pane throws are also caught:

```lua
local function drawer_action(name)
  return function()
    local ok, err = pcall(function()
      if not dbee.is_open() then dbee.open() end
      if not dbee.is_open() then
        utils.log("warn", "Failed to open drawer; cannot run " .. name)
        return
      end
      dbee.focus_pane("drawer")
      api.ui.drawer_do_action(name)
    end)
    if not ok then
      utils.log("error", "drawer action " .. name .. " failed: " .. tostring(err))
    end
  end
end
```

Add 4 entries to the `actions` table at line 1537:
```lua
{ id = "add_folder",                  label = "+ New Folder",              run = drawer_action("add_folder") },
{ id = "rename_folder",               label = "Rename Folder",             run = drawer_action("rename_folder") },
{ id = "delete_folder",               label = "Delete Folder",             run = drawer_action("delete_folder") },
{ id = "move_connection_to_folder",   label = "Move Connection To Folder", run = drawer_action("move_connection_to_folder") },
```

Add public API wrappers: `dbee.add_folder = drawer_action("add_folder")` etc. NEVER throws.

---

### Layer 7: model.lua — folder topology + cached-vs-visible preservation (`lua/dbee/ui/drawer/model.lua`)

Modify:
- `SEARCHABLE_TYPES` (line 5) → add `folder = true`.
- `DrawerRenderNode` typedef (line 19) → add `folder_id?: string`.
- `to_render_node()` (line 87) → copy `folder_id`, `source_meta`, `search_text`.
**`structure_cache_has_ready(structure_cache, conn_id)` predicate** — defined inline in model.lua. EXACT mirror of existing readiness check at `model.lua:63` (handles BOTH `structure_cache.root[conn_id]` AND direct `structure_cache[conn_id]` fallback):
```lua
local function structure_cache_has_ready(structure_cache, conn_id)
  local cached = structure_cache and structure_cache.root and structure_cache.root[conn_id]
              or structure_cache and structure_cache[conn_id]
  return cached ~= nil and not cached.error
end
```

- `M.build_search_model()` (line 192) — restructure to mirror drawer topology AND preserve cached-vs-visible semantics. Build TWO SEPARATE sets per source (`ready_conn_ids` is a subset of `all_search_conn_ids`, NOT disjoint):
  - `all_search_conn_ids[conn_id] = true` for **every** connection that gets into the search model — used by `merge_visible_connection_rows()` for duplicate suppression (so a fallback connection row isn't added on top of an existing folder-child render).
  - `ready_conn_ids[conn_id] = true` ONLY for connections whose `structure_cache_has_ready(structure_cache, conn.id)` returns true — used ONLY for `visible_uncached_connections` / fallback-search hint (NOT for the "N of M structures cached" coverage label, which uses `coverage.ready_connections`).

  **Explicit pseudocode for collecting both sets:**
  ```lua
  -- After build_search_model returns (search_model, coverage):
  local function collect_ids(node, all_ids, ready_ids)
    if node.type == "connection" and node.conn_id then
      all_ids[node.conn_id] = true
      if node.structure_ready == true then
        ready_ids[node.conn_id] = true
      end
    end
    for _, child in ipairs(node.children or {}) do
      collect_ids(child, all_ids, ready_ids)
    end
  end

  -- caller side (e.g. in merge_visible_connection_rows or build_search_model post-pass):
  local all_search_conn_ids, ready_conn_ids = {}, {}
  for _, root in ipairs(search_model) do
    collect_ids(root, all_search_conn_ids, ready_conn_ids)
  end
  ```

  **Caller contract (build_search_model RETURNS):**
  - `search_model: table[]` (existing return, augmented with folder topology)
  - `coverage: { ready_connections: integer, total_connections: integer }` (existing return, computed in same per-source loop)
  - `all_search_conn_ids: table<string, true>` (NEW return; collected via collect_ids walk after model build)
  - `ready_conn_ids: table<string, true>` (NEW return; collected via collect_ids walk after model build)

  **`merge_visible_connection_rows()` signature update** — accept the two new sets as additional args (or read them off a context table). Behavior — SINGLE-VALUED contract (no ambiguity):
  - For dedupe: skip connection IDs already in `all_search_conn_ids` when adding fallback rows.
  - For "structures cached" count: use **`coverage.ready_connections`** (already computed in build_search_model). This is the TOTAL count of structure-ready connections across all sources — same semantics as pre-folder behavior. Coverage label format:
    ```
    string.format("visible rows + %d of %d structures cached", coverage.ready_connections, coverage.total_connections)
    ```
  - `visible_uncached_connections` (existing field) stays separate and is computed from visible rows minus rows whose conn_id is in `ready_conn_ids` — used ONLY for the fallback-search hint.
  - `ready_conn_ids` exists for `visible_uncached_connections` calculation; `coverage.ready_connections` exists for the "N of M cached" coverage label. They are NOT interchangeable; both serve distinct purposes.

  **All callers of build_search_model** must be updated to receive the 4-tuple return AND pass `all_search_conn_ids` + `ready_conn_ids` to merge_visible_connection_rows. (Compatibility shim: existing callers using just `search_model, coverage` still work via Lua's drop-extra-returns; only filter UI path needs the new args.)

```lua
function M.build_search_model(handler, structure_cache)
  local coverage = { ready_connections = 0, total_connections = 0 }
  local search_model = {}
  local root_id = "__handler_root__"

  for _, source in ipairs(handler:get_sources()) do
    local source_id = source:name()
    local source_meta = { id = source_id, name = ..., file = ..., can_create = ..., can_update = ..., can_delete = ... }

    -- ONE call each per source (asserted by FOLDER15_BUILD_SEARCH_MODEL_CALL_COUNT_OK)
    local conns = handler:source_get_connections(source_id)
    local folders = handler:source_get_folders(source_id)

    -- Coverage pass + ready_set in single iteration
    local ready_set = {}
    for _, c in ipairs(conns) do
      coverage.total_connections = coverage.total_connections + 1
      local ready = structure_cache_has_ready(structure_cache, c.id)
      if ready then
        coverage.ready_connections = coverage.ready_connections + 1
        ready_set[c.id] = true
      end
    end

    -- conn_by_id index for folder iteration
    local conn_by_id = {}
    for _, c in ipairs(conns) do conn_by_id[c.id] = c end

    local in_folder = {}

    -- Folder topology
    for _, folder in ipairs(folders) do
      local children = {}
      for _, conn_id in ipairs(folder.connection_ids or {}) do
        local conn = conn_by_id[conn_id]
        if conn then
          in_folder[conn_id] = true
          children[#children+1] = build_search_connection_node(conn, source_meta, structure_cache, ready_set[conn_id])
        end
      end
      search_model[#search_model+1] = {
        id = convert.folder_node_id(root_id, source_id, folder.id),
        name = folder.name,
        type = "folder",
        raw_name = folder.name,
        folder_id = folder.id,
        source_meta = source_meta,
        search_text = folder.name,
        children = children,
      }
    end

    -- Ungrouped at source root
    for _, conn in ipairs(conns) do
      if not in_folder[conn.id] then
        search_model[#search_model+1] = build_search_connection_node(conn, source_meta, structure_cache, ready_set[conn.id])
      end
    end
  end

  -- Build all_search_conn_ids + ready_conn_ids via single recursive walk
  local all_search_conn_ids, ready_conn_ids = {}, {}
  local function collect_ids(node)
    if node.type == "connection" and node.conn_id then
      all_search_conn_ids[node.conn_id] = true
      if node.structure_ready == true then
        ready_conn_ids[node.conn_id] = true
      end
    end
    for _, child in ipairs(node.children or {}) do
      collect_ids(child)
    end
  end
  for _, root_node in ipairs(search_model) do
    collect_ids(root_node)
  end

  return search_model, coverage, all_search_conn_ids, ready_conn_ids
end
```

**Caller updates required:**
- `cached_search_model` schema (existing) extends to store `{ search_model, coverage, all_search_conn_ids, ready_conn_ids }` (table or 4 fields).
- Filter UI caller stores all 4 fields on first build, passes `all_search_conn_ids` + `ready_conn_ids` into `merge_visible_connection_rows()`.
- Other callers (e.g. coverage display only) can use Lua's drop-extra-returns and continue to receive only `search_model, coverage`.

`build_search_connection_node(conn, source_meta, structure_cache, structure_ready)` — extends existing pattern; sets `structure_ready = bool` field on the search node. The `structure_ready` field is the BUILD-TIME source for populating `ready_conn_ids` via the collect_ids walk. `merge_visible_connection_rows()` reads `ready_conn_ids` (NOT `structure_ready` directly) and computes `visible_uncached_connections` as visible snapshot rows minus rows whose conn_id ∈ ready_conn_ids.

Render-time `connection_coverage()` at `model.lua:53` is UNCHANGED — out of scope. Only `build_search_model()` is folded.

---

### Layer 8: Drawer snapshot/hydrate threading (`lua/dbee/ui/drawer/init.lua`)

Update each cited site to copy `folder_id`, `conn_id`, `source_meta`, `search_text`:

- `clone_rendered_snapshot()` (line 448)
- `snapshot_to_tree_nodes()` (line 486)
- `searchable_node_to_tree_node()` (line 581) → ALSO add NEW branch BEFORE `SEARCHABLE_TYPES` check at line 602:
  ```lua
  if node.type == "connection" and node.source_meta then
    convert.decorate_connection_node(...)  -- existing
  elseif node.type == "folder" and node.source_meta and node.folder_id then
    convert.decorate_folder_node(tree_node, ui.handler, node.source_meta, node.folder_id)
  elseif SEARCHABLE_TYPES[node.type] then
    -- existing structure-node branch
  end
  ```
- snapshot copy points at line 539-541, 591-593
- `hydrate()` at line 3616 — add `folder_id`, `conn_id`, `source_meta`, `search_text` to NuiTree.Node fields. After Node creation:
  ```lua
  if model_node.type == "folder" and model_node.source_meta and model_node.folder_id then
    convert.decorate_folder_node(node, self.handler, model_node.source_meta, model_node.folder_id)
  end
  ```

---

### Layer 9: connection_invalidated wiring + bootstrap replay

Drawer's existing `_connection_invalidated_consumer` (`drawer/init.lua:1014`) refreshes on `connection_invalidated`. Folder mutations emit this event with reason `"folder_mutation"` (Layer 3). NO new event type needed.

**Bootstrap replay rule:** The actual drop happens in `drawer/init.lua:717` via `should_apply_bootstrap_invalidation()` returning false when `authoritative_root_epoch <= 0`. Fix: add a replay-safe rule in the DRAWER predicate (NOT the handler):

```lua
local function should_apply_bootstrap_invalidation(data)
  if data and data.reason == "folder_mutation" then
    return true  -- folder mutations have no epoch implication; always replay
  end
  -- existing epoch gating
  ...
end
```

Folder mutations only signal "drawer needs to re-render folder topology" — independent of LSP cache epochs. Test marker `FOLDER15_BOOTSTRAP_REPLAY_FOLDER_MUTATION_OK` lives in Wave 4 (drawer init.lua edits).

---

## Files & estimated diffs

| File | Action | LOC |
|------|--------|-----|
| `lua/dbee/sources.lua` | Folder type, FileSource methods, supports_folders, atomic-write reuse, normalize, delete-prune-folder, load-failed contract, reload_folders | +280 |
| `lua/dbee/handler/init.lua` | source_*_folder pass-through (4 methods + _require), reload hook on source reload | +140 |
| `lua/dbee/ui/drawer/convert.lua` | folder_node_id helper, build_folder_node, build_connection_node refactor, partition, decorate_folder_node | +220 |
| `lua/dbee/ui/drawer/init.lua` | DrawerUINode.type union += "folder", folder_id field, _guarded_folder_mutation, 4 drawer-level actions, snapshot/hydrate field threading (5 sites), folder decoration in hydrate + searchable_node_to_tree_node | +280 |
| `lua/dbee/ui/drawer/model.lua` | folder searchable, folder_id+search_text in to_render_node, build_search_model folder topology + ready_set semantics, structure_ready field on conn nodes | +140 |
| `lua/dbee.lua` | drawer_action helper, 4 entries in actions table + 4 public dbee.* wrappers | +60 |
| `ci/headless/check_folder_persistence.lua` (NEW) | Atomic write, normalize, missing file, all CRUD, idempotent move, corrupt sidecar no-overwrite, delete-conn prune, reload_folders | +400 |
| `ci/headless/check_drawer_folders.lua` (NEW) | Drawer rendering, all 4 actions wired, refresh on connection_invalidated, ungrouped fallback, model filter folder topology, expansion preservation, snapshot threading, perf, node_id collision-safe, dbee.actions includes folder ops, 3-duplicate-name picker, visible_uncached preserved, drawer-closed action no-throw | +540 |
| `Makefile` | Add new tests to UX13 rollup | +2 |
| `ci/headless/check_ux13_rollup.lua` | Add FOLDER15_ALL_PASS to UX13 rollup marker list | +5 |

**Total estimated:** ~2067 LOC additions.

---

## Sentinel markers

Strict family `FOLDER15_*` — **40 strict + 1 diagnostic** (perf is diagnostic only, NOT in `FOLDER15_ALL_PASS`).

### Persistence tests (`check_folder_persistence.lua`) — 19 strict

| Marker | Asserts |
|--------|---------|
| `FOLDER15_SIDECAR_PATH_DERIVES_OK` | `.json` → `.folders.json`, no-suffix → `+.folders.json`, double `.folders.json` → appended again |
| `FOLDER15_LOAD_MISSING_FILE_EMPTY_OK` | Missing → empty list, no error, state = loaded_ok |
| `FOLDER15_LOAD_DUPE_CONN_DEDUPED_OK` | Conn ID in 2 folders → keeps first, in-memory dedupe |
| `FOLDER15_LOAD_DROPS_MISSING_CONN_OK` | folder.connection_ids referencing missing conn → dropped from cache |
| `FOLDER15_LOAD_NO_AUTO_REWRITE` | Self-heal does NOT touch disk |
| `FOLDER15_CORRUPT_SIDECAR_NO_OVERWRITE` | All malformed shapes (JSON decode fail, `{}`, keyed objects, `[1]`, bad connection_ids) → state = load_failed, all 4 mutations error via `_require_folders_writeable`, sidecar untouched |
| `FOLDER15_ADD_FOLDER_PERSISTS_OK` | add_folder writes; reload sees |
| `FOLDER15_ADD_FOLDER_DUPE_NAME_REJECTS` | Dupe case-insensitive → error, no write |
| `FOLDER15_RENAME_FOLDER_KEEPS_MEMBERS` | Rename preserves connection_ids order + content |
| `FOLDER15_REMOVE_FOLDER_UNGROUPS_CONNS` | Remove → next reload connections ungrouped |
| `FOLDER15_MOVE_CONN_INTO_FOLDER_OK` | Move from ungrouped → folder, persists |
| `FOLDER15_MOVE_CONN_BETWEEN_FOLDERS_OK` | Move A → B removes from A |
| `FOLDER15_MOVE_CONN_OUT_TO_UNGROUPED_OK` | move(conn, nil) → ungrouped |
| `FOLDER15_MOVE_CONN_IDEMPOTENT_OK` | Re-move into same target → no disk write |
| `FOLDER15_ATOMIC_WRITE_TEMP_CLEANUP_OK` | Write fail → temp cleaned |
| `FOLDER15_ATOMIC_WRITE_RENAME_FAIL_OK` | Rename fail → original untouched |
| `FOLDER15_DELETE_CONN_PRUNES_FOLDER_MEMBERSHIP_OK` | FileSource:delete(conn) → conn removed from folder, both files coherent |
| `FOLDER15_RELOAD_FOLDERS_REREADS_DISK` | reload_folders() → next load re-reads modified file |
| `FOLDER15_DELETE_CONN_CORRUPT_SIDECAR_NO_BLOCK` | Corrupt sidecar during conn delete → conn delete succeeds + load_failed state set + warn |

### Drawer/UI tests (`check_drawer_folders.lua`) — 21 strict + 1 diagnostic

| Marker | Asserts |
|--------|---------|
| `FOLDER15_NON_FILESOURCE_DEGRADES_OK` | Non-folder source → drawer renders direct, drawer actions warn-no-op |
| `FOLDER15_DRAWER_FOLDER_NODE_RENDERED` | Folder appears between source and connections |
| `FOLDER15_DRAWER_UNGROUPED_AT_ROOT` | Ungrouped at source root |
| `FOLDER15_DRAWER_FOLDER_LAZY_CHILDREN_OK` | Folder expand → only its conns; partition correct |
| `FOLDER15_DRAWER_FOLDER_RENAME_ACTION_OK` | Folder action_2 triggers rename |
| `FOLDER15_DRAWER_FOLDER_DELETE_ACTION_OK` | Folder action_3 triggers delete confirm |
| `FOLDER15_DRAWER_LEVEL_ACTIONS_PRESENT` | get_actions().{add,rename,delete}_folder + move_connection_to_folder all present |
| `FOLDER15_DBEE_ACTIONS_PICKER_INCLUDES_FOLDER_OPS` | dbee.actions() list contains 4 folder action ids |
| `FOLDER15_DRAWER_INVALIDATE_REFRESH_OK` | folder_mutation → connection_invalidated → drawer rebuilds |
| `FOLDER15_DRAWER_FOLDER_FILTER_VISIBLE` | Filter matches folder name OR contained conn name; folder auto-expands |
| `FOLDER15_DRAWER_FOLDER_EXPANSION_PRESERVED` | Adding 2nd folder preserves first's expansion + cursor |
| `FOLDER15_DRAWER_SNAPSHOT_FOLDER_THREADING_OK` | Initial render → hydrate → snapshot → filter restore preserves folder action_2/action_3 + folder_id + source_meta |
| `FOLDER15_HYDRATE_FOLDER_FIELDS_OK` | hydrate() copies folder_id, conn_id, source_meta, search_text + decorates folder nodes |
| `FOLDER15_FILTERED_FOLDER_DECORATION_OK` | searchable_node_to_tree_node folder branch decorates folder action_2/3 after filter restore |
| `FOLDER15_FOLDER_NODE_ID_COLLISION_SAFE` | source/folder ids containing ID_SEP or `:` → escaped via folder_node_id, no collision |
| `FOLDER15_DRAWER_FOLDER_MUTATION_ERROR_RECOVER_OK` | All 4 mutations: pcall + log + on_done callback fires; dispatcher unblocks |
| `FOLDER15_DBEE_ACTIONS_CLOSED_DRAWER_NO_THROW` | Calling dbee.add_folder() etc. with drawer closed → opens drawer + runs OR warns; never throws |
| `FOLDER15_BUILD_SEARCH_MODEL_CALL_COUNT_OK` | source_get_folders + source_get_connections each called exactly once per source per build_search_model |
| `FOLDER15_MOVE_PICKER_3_DUPLICATE_NAMES_DISTINCT` | 3 folders same name → picker shows 3 distinct labels via tail-suffix |
| `FOLDER15_VISIBLE_UNCACHED_COUNT_PRESERVED_OK` | BOTH (a) cached coverage label "visible rows + N of M structures cached" matches pre-folder behavior (uses coverage.ready_connections), AND (b) visible_uncached_connections count derived from ready_conn_ids drives the fallback-search hint correctly with mixed cached/uncached + folders |
| `FOLDER15_BOOTSTRAP_REPLAY_FOLDER_MUTATION_OK` | folder_mutation events buffered during bootstrap drain replay correctly without authoritative_root_epoch |
| `FOLDER15_DRAWER_RENDER_PERF_DIAGNOSTIC` (diagnostic) | 50 folders × 20 conns render time reported; **NOT in FOLDER15_ALL_PASS** |

### Rollup

`FOLDER15_ALL_PASS` = AND of all 40 strict markers (excludes `FOLDER15_DRAWER_RENDER_PERF_DIAGNOSTIC`).

Plus existing smoke must remain green: `DRAW01_ALL_PASS`, `STRUCT01_ALL_PASS`, `DCFG01_DRAWER_LIFECYCLE_ALL_PASS`, `DCFG02_FILESOURCE_ALL_PASS`.

---

## Execute waves

**Wave 1 — Persistence (sources.lua + check_folder_persistence.lua).**
Folder type, FileSource methods, supports_folders, atomic-write reuse, normalize, in-memory cache, load-failed contract, delete-conn prune (including malformed-but-decodable JSON safety), reload_folders. ALL 19 persistence markers.

**Wave 2 — Handler facade (handler/init.lua).**
4 source_*_folder pass-through methods + _require_folder_capable_source, reload_folders hook on source_reload. Each emits connection_invalidated("folder_mutation"). No new tests; behavior validated via persistence + drawer tests.

**Wave 3 — Drawer rendering (convert.lua + minor init.lua).**
folder_node_id helper, build_folder_node, build_connection_node refactor, partition, decorate_folder_node, DrawerUINode.type union += "folder". Markers: `FOLDER15_DRAWER_FOLDER_NODE_RENDERED`, `_UNGROUPED_AT_ROOT`, `_FOLDER_LAZY_CHILDREN_OK`, `_RENAME_ACTION_OK`, `_DELETE_ACTION_OK`, `FOLDER15_NON_FILESOURCE_DEGRADES_OK`, `_INVALIDATE_REFRESH_OK`, `_FOLDER_NODE_ID_COLLISION_SAFE`, `FOLDER15_DRAWER_RENDER_PERF_DIAGNOSTIC`.

**Wave 4 — Drawer-level actions + snapshot/hydrate threading + bootstrap replay + move picker (init.lua).**
_guarded_folder_mutation; add/rename/delete/move actions using it. The `move_connection_to_folder` action constructs the move picker with unique_label (deterministic counter fallback for arbitrary duplicate counts). Snapshot/hydrate threading at the 5 sites (clone_rendered_snapshot, snapshot_to_tree_nodes, searchable_node_to_tree_node + folder branch, hydrate + folder decoration, snapshot copy 539-541/591-593). DRAWER-side bootstrap replay edit at `should_apply_bootstrap_invalidation()` (drawer/init.lua:717) → folder_mutation always replays. Markers: `_LEVEL_ACTIONS_PRESENT`, `_SNAPSHOT_FOLDER_THREADING_OK`, `_MUTATION_ERROR_RECOVER_OK`, `_FILTERED_FOLDER_DECORATION_OK`, `_HYDRATE_FOLDER_FIELDS_OK`, `FOLDER15_BOOTSTRAP_REPLAY_FOLDER_MUTATION_OK`, `FOLDER15_MOVE_PICKER_3_DUPLICATE_NAMES_DISTINCT`.

**Wave 5 — model.lua + filter (model.lua).**
build_search_model folder topology with single-pass conn_by_id + ready_set per source. Coverage folded into per-source loop. structure_ready field set on conn search nodes (build-time source for ready_conn_ids). SEARCHABLE_TYPES += folder. to_render_node field copy. merge_visible_connection_rows reads `ready_conn_ids` (generated from structure_ready during collect_ids walk) for visible_uncached calculation, and uses `coverage.ready_connections` for the cached coverage label. Markers: `_FOLDER_FILTER_VISIBLE`, `_FOLDER_EXPANSION_PRESERVED`, `_BUILD_SEARCH_MODEL_CALL_COUNT_OK`, `_VISIBLE_UNCACHED_COUNT_PRESERVED_OK`.

**Wave 6 — Top-level API + actions picker + closed-drawer guard (dbee.lua).**
drawer_action() helper (whole-body pcall). 4 entries in actions table at line 1537 + 4 public wrappers. Markers: `_DBEE_ACTIONS_PICKER_INCLUDES_FOLDER_OPS`, `_DBEE_ACTIONS_CLOSED_DRAWER_NO_THROW`.

(Note: `FOLDER15_MOVE_PICKER_3_DUPLICATE_NAMES_DISTINCT` is allocated to **Wave 4** because it validates drawer move-picker logic at `init.lua` get_actions().move_connection_to_folder, not the dbee.lua picker entries.)

**Wave 7 — Rollup + Makefile + final smoke.**
Add tests to Makefile UX13 rollup loop. Add FOLDER15 line to UX13 sentinel summary. Run full smoke: DRAW01 + STRUCT01 + DCFG01 + DCFG02 + new FOLDER15 must all pass.

---

## Risks / non-obvious gotchas

1. **Drawer filter folder visibility.** Folder visible if name matches OR any child matches; auto-expand on child match. Mirrors schema match-via-children pattern.
2. **Drawer reorder preserves expansion.** STRUCT-01 snapshot/restore handles. Tested via `_FOLDER_EXPANSION_PRESERVED`.
3. **conn_id uniqueness across folders.** Validated at load (normalize) + every move (single-pass remove-then-insert).
4. **Source has no folder support.** `supports_folders()` gates. Drawer-level actions warn-no-op if no folder-capable source. move_connection_to_folder also pre-checks the conn's source.
5. **Sidecar basename collision.** `*.folders.json` re-suffixed (well-defined).
6. **JSON encode order.** Lua array order preserved by vim.json.encode.
7. **Concurrent edits across nvim instances.** No locking — last writer wins (same as connections.json today).
8. **Empty folder.** Renders normally as expandable empty branch.
9. **Move-into-self / nonexistent.** Validate target exists before move; nil always valid.
10. **Cache invalidation on source.reload.** `source:reload_folders()` called from Handler reload path.
11. **Folder ID stable across rename.** Rename mutates name only, not id → tree node id stable, no rebuild surprise.
12. **Folder render ordering.** folders[] insertion order. Rename does NOT reorder. v1.4 may add explicit reorder.
13. **Connection deletion prunes folder.** FileSource:delete handles atomically. If folder write fails post-delete, log error; next mutation re-prunes.
14. **Corrupt sidecar.** State=load_failed locks ALL mutations. User must delete sidecar or fix JSON; reload_folders() re-attempts.
15. **Cold-render disk read.** Acceptable: first load_folders per session reads disk once; cached thereafter. No render-loop disk re-read.
16. **Snapshot threading.** All 5 snapshot/hydrate sites must copy folder_id + source_meta or rename/delete actions break after filter restore. Tested.
17. **`dbee.actions()` picker.** 4 new entries; rename/delete/move require specific cursor types — entries warn-no-op silently if mismatched.
18. **drawer_action whole-body pcall.** Guarantees no throw across is_open / open / focus_pane / drawer_do_action chain.
19. **Move picker label collision.** 3+ folders with same name → unique_label tail-suffix loop with deterministic counter fallback.
20. **build_search_model preserves cached-vs-visible.** ready_set per source + structure_ready field on conn search nodes (build-time source). merge_visible_connection_rows reads `ready_conn_ids` (collected from structure_ready) for visible_uncached count, and uses `coverage.ready_connections` for the "N of M cached" label.

## Out of scope (v1.4+)

- Nested folders
- Drag-to-reorder folders/connections
- Color tags / per-folder template
- Bulk multi-select move
- DBeaver workspace import
- `:Dbee folder_*` commands
- Auto-recovery from corrupt sidecar (require manual intervention)

## Success criteria

- All 40 FOLDER15 strict markers green. (`FOLDER15_DRAWER_RENDER_PERF_DIAGNOSTIC` reported as diagnostic only.)
- `DRAW01_ALL_PASS`, `STRUCT01_ALL_PASS`, `DCFG01_DRAWER_LIFECYCLE_ALL_PASS`, `DCFG02_FILESOURCE_ALL_PASS` unchanged.
- User can: create folder, move connection in/out/between, rename folder, delete folder (members ungrouped), persist across nvim restart.
- Existing users with no folders.json see ZERO behavior change.
- Atomic-write contract holds.
- Corrupt sidecar → user notified, no overwrite.
- Drawer render perf for 50 folders × 20 conns reported (target < 50ms advisory).
