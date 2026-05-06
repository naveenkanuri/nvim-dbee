-- Headless validation for Phase 23 Wave 1 folder-scoped notes behavior.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_folder_scoped_notes.lua"

local function fail(msg)
  print("FOLDER_SCOPED_NOTES_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. vim.inspect(value))
  end
end

local function assert_false(label, value)
  if value then
    fail(label .. ": expected falsey, got " .. vim.inspect(value))
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local function assert_match(label, actual, pattern)
  if type(actual) ~= "string" or not actual:find(pattern, 1, true) then
    fail(label .. ": expected " .. vim.inspect(actual) .. " to contain " .. vim.inspect(pattern))
  end
end

local function assert_errors(label, fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    fail(label .. ": expected error")
  end
  if pattern then
    assert_match(label .. "_message", tostring(err), pattern)
  end
end

local function emit(marker)
  print(marker .. "=true")
end

local notifications = {}
local saved_notify = vim.notify
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

local function clear_notifications()
  notifications = {}
end

local function last_notification()
  return notifications[#notifications] or {}
end

package.loaded["dbee.reconnect"] = {
  register_connection_rewritten_listener = function() end,
  forget_call = function() end,
}

local function write_file(path, content)
  local file = assert(io.open(path, "w"))
  file:write(content)
  file:close()
end

local function write_json(path, records)
  local ok, encoded = pcall(vim.fn.json_encode, records)
  if not ok then
    fail("json encode failed for " .. tostring(path))
  end
  write_file(path, encoded)
end

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local function make_temp_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function cleanup_path(path)
  if path and path ~= "" then
    pcall(vim.fn.delete, path, "rf")
  end
end

local function install_dbee_functions(runtime)
  local events = require("dbee.handler.__events")

  vim.fn.DbeeDeleteConnection = function(conn_id)
    runtime.connections[conn_id] = nil
  end

  vim.fn.DbeeCreateConnection = function(spec)
    runtime.connections[spec.id] = vim.deepcopy(spec)
    if runtime.current_conn_id == nil then
      runtime.current_conn_id = spec.id
    end
    return spec.id
  end

  vim.fn.DbeeGetConnections = function(conn_ids)
    local out = {}
    for _, conn_id in ipairs(conn_ids or {}) do
      if runtime.connections[conn_id] then
        out[#out + 1] = vim.deepcopy(runtime.connections[conn_id])
      end
    end
    return out
  end

  vim.fn.DbeeGetCurrentConnection = function()
    if runtime.current_conn_id and runtime.connections[runtime.current_conn_id] then
      return vim.deepcopy(runtime.connections[runtime.current_conn_id])
    end
    return vim.NIL
  end

  vim.fn.DbeeSetCurrentConnection = function(conn_id)
    runtime.current_conn_id = conn_id
    events.trigger("current_connection_changed", { conn_id = conn_id, cleared = false })
  end

  vim.fn.DbeeClearCurrentConnection = function()
    runtime.current_conn_id = nil
    events.trigger("current_connection_changed", { conn_id = vim.NIL, cleared = true })
  end

  vim.fn.DbeeConnectionGetParams = function(conn_id)
    return runtime.connections[conn_id] and vim.deepcopy(runtime.connections[conn_id]) or vim.NIL
  end

  vim.fn.DbeeConnectionGetHelpers = function()
    return {}
  end

  vim.fn.DbeeConnectionGetCalls = function()
    return {}
  end
end

local function make_source(dir, basename, records, folders)
  local path = vim.fs.joinpath(dir, basename)
  write_json(path, records)
  local source = require("dbee.sources").FileSource:new(path)
  if folders ~= nil then
    if type(folders) == "string" then
      write_file(source:folders_path(), folders)
    else
      write_json(source:folders_path(), folders)
    end
  end
  return source
end

local function make_handler(sources, current_conn_id)
  local runtime = {
    connections = {},
    current_conn_id = current_conn_id,
  }
  install_dbee_functions(runtime)
  local Handler = require("dbee.handler")
  local handler = Handler:new(sources)
  return handler, runtime
end

local function make_result_stub()
  return {
    clear = function() end,
    restore_call = function() end,
    set_call = function() end,
  }
end

local function run_source_handler_contracts()
  local dir = make_temp_dir()
  local ok, err = pcall(function()
    local source = make_source(dir, "source-main.json", {
      { id = "conn-a", name = "A", type = "postgres", url = "postgres://a" },
      { id = "conn-b", name = "B", type = "postgres", url = "postgres://b" },
      { id = "conn-c", name = "C", type = "postgres", url = "postgres://c" },
    }, {
      { id = "folder_One123", name = "One", connection_ids = { "conn-a", "conn-b" } },
      { id = "folder_Two123", name = "Two", connection_ids = { "conn-a", "conn-c" } },
    })

    assert_true("source method exists", type(source.get_folder_for_connection) == "function")
    local folder_a = source:get_folder_for_connection("conn-a")
    local folder_c = source:get_folder_for_connection("conn-c")
    assert_eq("source conn-a first folder", folder_a.id, "folder_One123")
    assert_eq("source conn-c second folder", folder_c.id, "folder_Two123")
    emit("GN23_SOURCE_FOLDER_LOOKUP_API_OK")
    emit("GN23_SINGLE_FOLDER_LOOKUP_OK")

    local handler = make_handler({ source }, "conn-a")
    local meta = handler:get_folder_for_connection("conn-a")
    assert_eq("handler source id", meta.source_id, "source-main.json")
    assert_eq("handler folder id", meta.folder_id, "folder_One123")
    assert_eq("handler folder name", meta.folder_name, "One")
    local counts, error_kind = handler:list_all_folder_ids_across_sources()
    assert_eq("handler counts folder one", counts.folder_One123, 1)
    assert_eq("handler counts error kind", error_kind, nil)

    local reloads = 0
    local original_ensure = source._ensure_folders_loaded
    source._folders_load_state = "unloaded"
    source._folders_cache = nil
    function source:_ensure_folders_loaded()
      if self._folders_load_state == "unloaded" then
        reloads = reloads + 1
      end
      return original_ensure(self)
    end
    handler:get_folder_for_connection("conn-a")
    for _ = 1, 100 do
      handler:get_folder_for_connection("conn-b")
    end
    assert_eq("memoized folder reads", reloads, 1)
    emit("GN23_FOLDER_READ_PATH_NO_INVALIDATE_OK")
  end)
  cleanup_path(dir)
  if not ok then
    fail(err)
  end
end

local function run_handler_defensive_contracts()
  local list_source = {
    _id = "list-source",
    name = function(self)
      return self._id
    end,
    load = function()
      return { { id = "conn-list", name = "List", type = "postgres", url = "postgres://list" } }
    end,
    supports_folders = function()
      return true
    end,
    load_folders = function()
      return { { id = "folder_List123", name = "List", connection_ids = { "conn-list" } } }
    end,
    get_folder_for_connection = function()
      return {
        { id = "folder_List123", name = "List", connection_ids = { "conn-list" } },
        { id = "folder_Other123", name = "Other", connection_ids = { "conn-list" } },
      }
    end,
  }
  local handler = make_handler({ list_source }, "conn-list")
  clear_notifications()
  assert_eq("list source fails closed", handler:get_folder_for_connection("conn-list"), nil)
  assert_eq("list source notify level", last_notification().level, vim.log.levels.ERROR)
  emit("GN23_HANDLER_FACADE_DEFENSIVE_OK")
end

local function run_collision_and_load_uncertainty_contracts()
  local dir = make_temp_dir()
  local ok, err = pcall(function()
    local source_a = make_source(dir, "source-a.json", {
      { id = "conn-a", name = "A", type = "postgres", url = "postgres://a" },
    }, {
      { id = "folder_Dup123", name = "Dup A", connection_ids = { "conn-a" } },
    })
    local source_b = make_source(dir, "source-b.json", {
      { id = "conn-b", name = "B", type = "postgres", url = "postgres://b" },
    }, {
      { id = "folder_Dup123", name = "Dup B", connection_ids = { "conn-b" } },
    })
    local handler = make_handler({ source_a, source_b }, "conn-a")
    local counts = handler:list_all_folder_ids_across_sources()
    assert_eq("duplicate count", counts.folder_Dup123, 2)
    clear_notifications()
    assert_eq("duplicate lookup nil", handler:get_folder_for_connection("conn-a"), nil)
    assert_match("duplicate notify", last_notification().msg, "exists in multiple sources")
    emit("GN23_RUNTIME_CROSS_SOURCE_COLLISION_OK")

    local corrupt = make_source(dir, "source-corrupt.json", {
      { id = "conn-corrupt", name = "Corrupt", type = "postgres", url = "postgres://corrupt" },
    }, "not-json")
    local corrupt_handler = make_handler({ corrupt }, "conn-corrupt")
    local _, load_error_kind = corrupt_handler:list_all_folder_ids_across_sources()
    assert_eq("load uncertainty list", load_error_kind, "load_failed")
    local folder, lookup_error_kind = corrupt_handler:get_folder_for_connection("conn-corrupt")
    assert_eq("load uncertainty folder", folder, nil)
    assert_eq("load uncertainty lookup", lookup_error_kind, "load_failed")
    emit("GN23_FOLDER_LOAD_UNCERTAINTY_FAIL_CLOSED_OK")
    emit("GN23_ERROR_KIND_VOCAB_LOCKED_OK")
  end)
  cleanup_path(dir)
  if not ok then
    fail(err)
  end
end

local function run_namespace_contracts()
  local dir = make_temp_dir()
  local ok, err = pcall(function()
    local notes_namespace = require("dbee.notes_namespace")
    assert_true("valid folder id", notes_namespace.validate_folder_id("folder_Abc123"))
    for _, invalid in ipairs({ "", "folder", "Folder_abc", "folder_a/b", "folder_a.b", "..", "folder_-x" }) do
      assert_false("invalid folder id " .. tostring(invalid), notes_namespace.validate_folder_id(invalid))
    end
    assert_true("prefix exact", notes_namespace.has_folder_prefix("folder:folder_Abc123"))
    assert_false("prefix anchored", notes_namespace.has_folder_prefix("my:folder:folder_Abc123"))
    assert_false("prefix case", notes_namespace.has_folder_prefix("Folder:folder_Abc123"))
    assert_true("is malformed folder namespace", notes_namespace.is_folder_namespace("folder:bad id"))
    assert_eq("parse valid", notes_namespace.parse_folder_namespace("folder:folder_Abc123"), "folder_Abc123")
    assert_eq("parse invalid", notes_namespace.parse_folder_namespace("folder:bad id"), nil)
    emit("GN23_FOLDER_PREFIX_RESERVED_OK")

    local handler = {
      source_conn_lookup = { ["source-main"] = { "conn-a" } },
      _source_id_for_connection = function(_, conn_id)
        return conn_id == "conn-a" and "source-main" or nil
      end,
      get_current_connection = function()
        return { id = "conn-a", name = "A", type = "postgres" }
      end,
      register_event_listener = function() end,
      list_all_folder_ids_across_sources = function()
        return { folder_Abc123 = 1 }
      end,
    }
    local EditorUI = require("dbee.ui.editor")
    local editor = EditorUI:new(handler, make_result_stub(), { directory = dir })

    assert_errors("raw folder create", function()
      editor:namespace_create_note("folder:folder_Abc123", "raw")
    end, "authority")
    assert_errors("raw folder read", function()
      editor:namespace_get_notes("folder:folder_Abc123")
    end, "authority")

    local created, create_err =
      notes_namespace.create_note_in_folder(editor, dir, handler, "folder_Abc123", "shared")
    assert_true("folder create succeeded " .. tostring(create_err), created ~= nil)
    local notes, read_err = notes_namespace.read_folder_namespace_notes(editor, "folder_Abc123")
    assert_true("folder read succeeded " .. tostring(read_err), type(notes) == "table" and #notes == 1)
    assert_eq("folder read note", notes[1].name, "shared.sql")
    emit("GN23_FOLDER_NOTE_CREATE_ROUTED_THROUGH_AUTHORITY_OK")
    emit("GN23_FOLDER_NAMESPACE_READ_AUTHORITY_OK")

    for _, invalid_ns in ipairs({ "folder:", "folder:invalid id with spaces", "folder:.." }) do
      assert_errors("invalid folder create " .. invalid_ns, function()
        editor:namespace_create_note(invalid_ns, "bad", { from_authority = true })
      end)
    end
    emit("GN23_NAMESPACE_API_VALIDATES_FOLDER_ID_OK")

    for _, invalid_ns in ipairs({ "", "bad/ns", "bad\\ns", "bad..ns" }) do
      assert_errors("invalid namespace " .. invalid_ns, function()
        editor:namespace_create_note(invalid_ns, "bad")
      end, "invalid namespace")
    end
    emit("GN23_NAMESPACE_INPUT_VALIDATION_OK")

    local retired = "namespace 'global' has been retired in Phase 23; use folder:<id> namespace via notes_namespace authority"
    assert_errors("global create retired", function()
      editor:namespace_create_note("global", "bad")
    end, retired)
    assert_errors("global get retired", function()
      editor:namespace_get_notes("global")
    end, retired)
    assert_errors("global remove retired", function()
      editor:namespace_remove_note("global", "missing")
    end, retired)
    assert_errors("global load retired", function()
      editor:load_notes_from_disk("global")
    end, retired)
    emit("GN23_GLOBAL_NAMESPACE_RETIRED_ALL_PATHS_OK")

    local expected_exports = {
      "validate_folder_id",
      "has_folder_prefix",
      "is_folder_namespace",
      "parse_folder_namespace",
      "folder_namespace_id",
      "folder_namespace_dir",
      "ensure_folder_namespace",
      "read_folder_namespace_notes",
      "create_note_in_folder",
      "delete_folder_namespace",
      "list_existing_folder_namespaces",
      "recursive_rmdir",
    }
    for _, name in ipairs(expected_exports) do
      assert_eq("notes_namespace export " .. name, type(notes_namespace[name]), "function")
    end
    emit("GN23_NOTES_NAMESPACE_PUBLIC_INTERNAL_SPLIT_OK")
  end)
  cleanup_path(dir)
  if not ok then
    fail(err)
  end
end

local function make_api_fixture()
  local dir = make_temp_dir()
  local notes_dir = vim.fs.joinpath(dir, "notes")
  vim.fn.mkdir(notes_dir, "p")
  local notes_namespace = require("dbee.notes_namespace")
  local folder_a = "folder_Alpha123"
  local folder_b = "folder_Beta123"
  local handler = {
    source_conn_lookup = { ["source-main"] = { "conn-a", "conn-b", "conn-free" } },
    current_conn_id = "conn-a",
    _source_id_for_connection = function(_, conn_id)
      return (conn_id == "conn-a" or conn_id == "conn-b" or conn_id == "conn-free") and "source-main" or nil
    end,
    get_current_connection = function(self)
      local names = {
        ["conn-a"] = "Alpha",
        ["conn-b"] = "Beta",
        ["conn-free"] = "Free",
      }
      if not self.current_conn_id then
        return nil
      end
      return { id = self.current_conn_id, name = names[self.current_conn_id] or self.current_conn_id, type = "postgres" }
    end,
    register_event_listener = function() end,
    list_all_folder_ids_across_sources = function()
      return { [folder_a] = 1, [folder_b] = 1 }
    end,
    get_folder_for_connection = function(_, conn_id)
      if conn_id == "conn-a" then
        return { source_id = "source-main", folder_id = folder_a, folder_name = "Alpha Folder" }
      end
      if conn_id == "conn-b" then
        return { source_id = "source-main", folder_id = folder_b, folder_name = "Beta Folder" }
      end
      return nil
    end,
    get_folder_metadata = function(_, folder_id)
      if folder_id == folder_a then
        return { source_id = "source-main", folder_id = folder_a, folder_name = "Alpha Folder" }
      end
      if folder_id == folder_b then
        return { source_id = "source-main", folder_id = folder_b, folder_name = "Beta Folder" }
      end
      return nil
    end,
  }
  local editor = require("dbee.ui.editor"):new(handler, make_result_stub(), { directory = notes_dir })
  notes_namespace.create_note_in_folder(editor, notes_dir, handler, folder_a, "shared")
  notes_namespace.create_note_in_folder(editor, notes_dir, handler, folder_b, "history")
  local local_note = editor:namespace_create_note("conn-a", "local")
  local global_dir = vim.fs.joinpath(notes_dir, "global")
  vim.fn.mkdir(global_dir, "p")
  write_file(vim.fs.joinpath(global_dir, "legacy.sql"), "select 'legacy'")

  package.loaded["dbee.api.state"] = {
    is_ui_loaded = function()
      return true
    end,
    editor = function()
      return editor
    end,
    handler = function()
      return handler
    end,
  }
  package.loaded["dbee.api.ui"] = nil
  local api_ui = require("dbee.api.ui")
  return {
    dir = dir,
    notes_dir = notes_dir,
    editor = editor,
    handler = handler,
    api_ui = api_ui,
    folder_a = folder_a,
    folder_b = folder_b,
    local_note = local_note,
  }
end

local function run_api_contracts()
  local fixture = make_api_fixture()
  local ok, err = pcall(function()
    local sections = fixture.api_ui.editor_get_note_picker_sections()
    assert_eq("sections current folder", sections.current_folder.id, fixture.folder_a)
    assert_eq("sections global namespace", sections.global_namespace_id, "folder:" .. fixture.folder_a)
    assert_eq("sections global note", sections.global_notes[1].name, "shared.sql")
    assert_eq("sections local note", sections.local_notes[1].name, "local.sql")
    emit("GN23_PICKER_USES_FOLDER_NAMESPACE_OK")
    emit("GN23_LOCAL_NOTES_UNCHANGED_OK")

    for _, note in ipairs(sections.global_notes) do
      assert_false("legacy global note hidden", note.name == "legacy.sql")
    end
    local all_notes = fixture.api_ui.editor_get_all_notes()
    for _, note in ipairs(all_notes) do
      assert_false("active all notes no global", note.namespace == "global")
    end
    assert_eq("active folder namespace raw", all_notes[1].namespace, "folder:" .. fixture.folder_a)
    emit("GN23_NO_LEGACY_GLOBAL_FALLBACK_OK")
    emit("GN23_HISTORY_SEARCH_NO_GLOBAL_OK")

    local history_notes = fixture.api_ui.editor_get_notes_for_connection("conn-b")
    assert_eq("history by row count", #history_notes, 1)
    assert_eq("history by row folder", history_notes[1].namespace, "folder:" .. fixture.folder_b)
    emit("GN23_HISTORY_SEARCH_BY_ROW_CONNECTION_OK")

    fixture.handler.current_conn_id = "conn-free"
    local no_folder_sections = fixture.api_ui.editor_get_note_picker_sections()
    assert_eq("no folder namespace nil", no_folder_sections.global_namespace_id, nil)
    assert_eq("no folder notes empty", #no_folder_sections.global_notes, 0)
    emit("GN23_NO_FOLDER_NAMESPACE_EMPTY_OK")
  end)
  cleanup_path(fixture.dir)
  if not ok then
    fail(err)
  end
end

local function run_picker_contracts()
  local fixture = make_api_fixture()
  local ok, err = pcall(function()
    package.loaded["dbee.api"] = {
      core = {
        is_loaded = function()
          return true
        end,
      },
      ui = fixture.api_ui,
      setup = function() end,
      current_config = function()
        return {
          window_layout = {
            is_open = function()
              return true
            end,
          },
        }
      end,
    }
    package.loaded["dbee.install"] = { exec = function() end }
    package.loaded["dbee.config"] = { default = {}, merge_with_default = function(cfg) return cfg or {} end, validate = function() end }
    package.loaded["dbee.query_splitter"] = {}
    package.loaded["dbee.reconnect"] = { ensure_reconnect_listener = function() end }
    package.loaded["dbee.variables"] = {
      resolve_for_execute_async = function(query, _, cb)
        cb(query, nil, nil)
      end,
    }

    local picker_calls = {}
    package.loaded["snacks"] = {
      picker = function(opts)
        local picker = {
          opts = opts,
          list = {
            items = opts.items,
            cursor = 1,
            count = function(self)
              return #self.items
            end,
            current = function(self)
              return self.items[self.cursor]
            end,
            move = function(self, to, absolute)
              self.cursor = absolute and to or self.cursor + to
              self.cursor = math.max(1, math.min(#self.items, self.cursor))
            end,
            select = function() end,
            unselect = function()
              return false
            end,
            render = function() end,
          },
          resolved_layout = { cycle = true },
          close = function(self)
            self.closed = true
          end,
        }
        picker_calls[#picker_calls + 1] = picker
        return picker
      end,
    }

    package.loaded["dbee"] = nil
    local dbee = require("dbee")

    local function items()
      return picker_calls[#picker_calls].opts.items
    end

    fixture.handler.current_conn_id = "conn-a"
    dbee.pick_notes()
    assert_eq("foldered hint", items()[1].text, "<C-g> new global  ·  <C-l> new local (Alpha)")
    assert_eq("foldered global header", items()[2].text, "Global notes")

    fixture.handler.current_conn_id = "conn-free"
    dbee.pick_notes()
    assert_eq("ungrouped hint", items()[1].text, "<C-l> new local (Free)  ·  (add to folder for global notes)")
    assert_eq("ungrouped empty", items()[3].text, "Add this connection to a folder to enable global notes")

    fixture.handler.current_conn_id = nil
    dbee.pick_notes()
    assert_eq("no current hint", items()[1].text, "(open a connection to enable notes)")
    assert_eq("no current empty", items()[3].text, "Connect to a database to enable notes")
    emit("GN23_PICKER_HINT_ROW_PRESERVED_OK")

    fixture.handler.current_conn_id = "conn-a"
    local input_called = 0
    local saved_input = vim.ui.input
    vim.ui.input = function(_, cb)
      input_called = input_called + 1
      cb("created")
    end
    dbee.pick_notes()
    local before = #fixture.api_ui.editor_get_notes_for_connection("conn-a")
    picker_calls[#picker_calls].opts.actions.dbee_new_global_note(picker_calls[#picker_calls])
    local after = #fixture.api_ui.editor_get_notes_for_connection("conn-a")
    vim.ui.input = saved_input
    assert_eq("folder c-g prompts", input_called, 1)
    assert_eq("folder c-g creates", after, before + 1)
    emit("GN23_CG_CREATE_FOLDER_NOTE_OK")

    fixture.handler.current_conn_id = "conn-free"
    input_called = 0
    vim.ui.input = function(_, cb)
      input_called = input_called + 1
      cb("should-not-create")
    end
    clear_notifications()
    dbee.pick_notes()
    picker_calls[#picker_calls].opts.actions.dbee_new_global_note(picker_calls[#picker_calls])
    vim.ui.input = saved_input
    assert_eq("ungrouped c-g no prompt", input_called, 0)
    assert_eq(
      "ungrouped c-g notify",
      last_notification().msg,
      "Connection not in any folder; cannot create global note. Add to a folder first."
    )
    emit("GN23_CG_NO_FOLDER_ERROR_OK")
  end)
  cleanup_path(fixture.dir)
  if not ok then
    fail(err)
  end
end

local function run_drawer_contracts()
  local convert = read_file("lua/dbee/ui/drawer/convert.lua")
  assert_false("global master node removed", convert:find("__master_note_global__", 1, true) ~= nil)
  assert_false("global namespace call removed", convert:find('editor_namespace_nodes(editor, "global"', 1, true) ~= nil)
  emit("GN23_DRAWER_GLOBAL_MASTER_NODE_REMOVED_OK")
end

run_source_handler_contracts()
run_handler_defensive_contracts()
run_collision_and_load_uncertainty_contracts()
run_namespace_contracts()
run_api_contracts()
run_picker_contracts()
run_drawer_contracts()

vim.notify = saved_notify
vim.cmd("qa!")
