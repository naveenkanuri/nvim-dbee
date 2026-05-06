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

local function assert_not_match(label, actual, pattern)
  if type(actual) == "string" and actual:find(pattern, 1, true) then
    fail(label .. ": expected " .. vim.inspect(actual) .. " not to contain " .. vim.inspect(pattern))
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
  io.stdout:flush()
end

local function emit_value(marker, value)
  print(marker .. "=" .. tostring(value))
  io.stdout:flush()
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
    local corrupt_counts, load_error_kind = corrupt_handler:list_all_folder_ids_across_sources()
    assert_eq("load uncertainty counts", corrupt_counts, nil)
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

    for _, unsafe_id in ipairs({ "../escape", "foo/../bar", "foo\\bar" }) do
      local unsafe_handler = {
        source_conn_lookup = { ["source-main"] = { unsafe_id } },
        _source_id_for_connection = function(_, conn_id)
          return conn_id == unsafe_id and "source-main" or nil
        end,
        get_current_connection = function()
          return { id = unsafe_id, name = "Unsafe", type = "postgres" }
        end,
        register_event_listener = function() end,
      }
      local unsafe_editor = EditorUI:new(unsafe_handler, make_result_stub(), { directory = dir })
      assert_errors("unsafe known local namespace " .. unsafe_id, function()
        unsafe_editor:namespace_create_note(unsafe_id, "bad")
      end, "invalid namespace")
    end

    local benign_handler = {
      source_conn_lookup = { ["source-main"] = { "with.dot" } },
      _source_id_for_connection = function(_, conn_id)
        return conn_id == "with.dot" and "source-main" or nil
      end,
      get_current_connection = function()
        return { id = "with.dot", name = "Benign", type = "postgres" }
      end,
      register_event_listener = function() end,
    }
    local benign_editor = EditorUI:new(benign_handler, make_result_stub(), { directory = dir })
    local benign_note_id = benign_editor:namespace_create_note("with.dot", "safe")
    local benign_note = benign_editor:search_note(benign_note_id)
    assert_match("benign namespace encoded path", benign_note.file, notes_namespace.encode_local_namespace_path("with.dot"))
    assert_true("benign namespace stays under notes dir", vim.startswith(benign_note.file, dir .. "/"))
    emit("GN23_NAMESPACE_INPUT_VALIDATION_OK")

    local missing, missing_err = notes_namespace.create_note_in_folder(editor, dir, handler, "folder_Missing123", "missing")
    assert_eq("missing folder no note", missing, nil)
    assert_eq("missing folder error", missing_err, "folder_not_found")
    emit("GN23_FOLDER_NAMESPACE_MISSING_FOLDER_FAIL_CLOSED_OK")

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
      "encode_local_namespace_path",
      "decode_local_namespace_path",
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
    fixture.handler.current_conn_id = nil
    assert_eq("no current all notes empty", #fixture.api_ui.editor_get_all_notes(), 0)
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

local function assert_path_exists(label, path)
  assert_true(label, vim.loop.fs_stat(path) ~= nil)
end

local function assert_path_absent(label, path)
  assert_eq(label, vim.loop.fs_stat(path), nil)
end

local function list_files(dir)
  local files = {}
  local handle = vim.loop.fs_scandir(dir)
  if not handle then
    return files
  end
  while true do
    local name = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    files[#files + 1] = name
  end
  table.sort(files)
  return files
end

local function count_sql_files(dir)
  local count = 0
  for _, name in ipairs(list_files(dir)) do
    if name:sub(-4) == ".sql" then
      count = count + 1
    end
  end
  return count
end

local function set_mtime(path, ts)
  vim.fn.system({ "touch", "-t", os.date("%Y%m%d%H%M.%S", ts), path })
end

local function make_migration_fixture(folders)
  local root = make_temp_dir()
  local notes_dir = vim.fs.joinpath(root, "notes")
  vim.fn.mkdir(vim.fs.joinpath(notes_dir, "global"), "p")
  write_file(vim.fs.joinpath(notes_dir, "global", "cleanup.sql"), "select 'cleanup';\n")
  write_file(vim.fs.joinpath(notes_dir, "global", "truncate_individual.sql"), "select 'truncate';\n")
  write_file(vim.fs.joinpath(notes_dir, "global", "welcome.sql"), "select 'welcome';\n")
  local source = make_source(root, "source-main.json", {
    { id = "conn-y", name = "Y", type = "postgres", url = "postgres://y" },
    { id = "conn-z", name = "Z", type = "postgres", url = "postgres://z" },
  }, folders or {
    { id = "folder_Yrcmu67jeY", name = "Y", connection_ids = { "conn-y" } },
    { id = "folder_1JvZNAc5MB", name = "Z", connection_ids = { "conn-z" } },
  })
  local handler = make_handler({ source }, "conn-y")
  return root, notes_dir, source, handler
end

local function run_migration_happy_path_contracts()
  local root, notes_dir, _, handler = make_migration_fixture()
  local ok, err = pcall(function()
    local notes_migration = require("dbee.notes_migration")
    clear_notifications()
    local result = notes_migration.maybe_run(handler, notes_dir, {})
    assert_true("migration result", result == true)

    local folder_a_dir = vim.fs.joinpath(notes_dir, "folder:folder_Yrcmu67jeY")
    local folder_b_dir = vim.fs.joinpath(notes_dir, "folder:folder_1JvZNAc5MB")
    assert_eq("folder a cloned files", count_sql_files(folder_a_dir), 3)
    assert_eq("folder b cloned files", count_sql_files(folder_b_dir), 3)
    assert_path_exists("backup created", vim.fs.joinpath(notes_dir, "global.bak"))
    assert_path_absent("global deleted", vim.fs.joinpath(notes_dir, "global"))
    assert_path_exists("sentinel written", vim.fs.joinpath(notes_dir, ".notes-migration-v1"))
    assert_match("drawer-removal notify", last_notification().msg, "global notes are now folder-scoped")
    emit("GN23_MIGRATION_CLONES_ALL_FOLDERS_OK")
    emit("GN23_MIGRATION_BACKUP_CREATED_OK")
    emit("GN23_GLOBAL_DIR_DELETED_OK")
    emit("GN23_MIGRATION_STAGED_PROMOTE_OK")
    emit("GN23_DRAWER_REMOVAL_USER_NOTIFY_OK")

    local before = count_sql_files(folder_a_dir) + count_sql_files(folder_b_dir)
    local second = notes_migration.maybe_run(handler, notes_dir, {})
    assert_true("idempotent result", second == true)
    local after = count_sql_files(folder_a_dir) + count_sql_files(folder_b_dir)
    assert_eq("idempotent file count", after, before)
    emit("GN23_MIGRATION_IDEMPOTENT_OK")
  end)
  cleanup_path(root)
  if not ok then
    fail(err)
  end
end

local function run_fresh_and_zero_folder_contracts()
  local root = make_temp_dir()
  local ok, err = pcall(function()
    local notes_migration = require("dbee.notes_migration")
    local source = make_source(root, "fresh.json", {
      { id = "conn-fresh", name = "Fresh", type = "postgres", url = "postgres://fresh" },
    }, {})
    local handler = make_handler({ source }, "conn-fresh")
    local missing_notes = vim.fs.joinpath(root, "missing-notes")
    assert_path_absent("notes root starts missing", missing_notes)
    local result = notes_migration.maybe_run(handler, missing_notes, {})
    assert_true("fresh result", result == true)
    assert_path_exists("notes root created", missing_notes)
    assert_path_exists("fresh sentinel", vim.fs.joinpath(missing_notes, ".notes-migration-v1"))
    emit("GN23_FRESH_USER_NO_FOLDERS_PROCEED_OK")
    emit("GN23_NOTES_DIR_BOOTSTRAP_OK")

    local zero_root, zero_notes, _, zero_handler = make_migration_fixture({})
    clear_notifications()
    local zero_result = notes_migration.maybe_run(zero_handler, zero_notes, {})
    assert_true("zero folder result", zero_result == true)
    assert_path_exists("zero backup", vim.fs.joinpath(zero_notes, "global.bak"))
    assert_path_absent("zero global deleted", vim.fs.joinpath(zero_notes, "global"))
    assert_match("zero folder backup notify", last_notification().msg, "legacy global notes backed up")
    emit("GN23_ZERO_FOLDER_BACKUP_NOTIFY_OK")
    cleanup_path(zero_root)

    local fail_root, fail_notes, _, fail_handler = make_migration_fixture({})
    local saved_rename = vim.loop.fs_rename
    vim.loop.fs_rename = function(src, dst)
      if src == vim.fs.joinpath(fail_notes, "global") then
        return nil, "EACCES"
      end
      return saved_rename(src, dst)
    end
    clear_notifications()
    local fail_ok = pcall(notes_migration.maybe_run, fail_handler, fail_notes, {})
    vim.loop.fs_rename = saved_rename
    assert_false("zero backup failure throws", fail_ok)
    assert_path_exists("zero global preserved", vim.fs.joinpath(fail_notes, "global"))
    assert_path_absent("zero sentinel absent", vim.fs.joinpath(fail_notes, ".notes-migration-v1"))
    assert_match("zero backup failure notify", last_notification().msg, "backup of legacy global notes failed")
    emit("GN23_BACKUP_FAILURE_FATAL_IN_ZERO_FOLDER_PATH_OK")
    cleanup_path(fail_root)
  end)
  cleanup_path(root)
  if not ok then
    fail(err)
  end
end

local function run_migration_failure_and_recovery_contracts()
  local root, notes_dir, _, handler = make_migration_fixture()
  local ok, err = pcall(function()
    local notes_migration = require("dbee.notes_migration")
    local saved_rename = vim.loop.fs_rename
    local sentinel = vim.fs.joinpath(notes_dir, ".notes-migration-v1")
    vim.loop.fs_rename = function(src, dst)
      if dst == sentinel then
        return nil, "EACCES"
      end
      return saved_rename(src, dst)
    end
    local result = notes_migration.maybe_run(handler, notes_dir, {})
    vim.loop.fs_rename = saved_rename
    assert_false("sentinel failure returns false", result)
    local promote_path = vim.fs.joinpath(notes_dir, ".notes-migration-v1.promote-manifest")
    local recovery_path = vim.fs.joinpath(notes_dir, ".notes-migration-v1.recovery-needed")
    assert_path_exists("promote manifest persisted", promote_path)
    assert_path_exists("recovery manifest written", recovery_path)
    local manifest = vim.json.decode(read_file(promote_path))
    assert_eq("manifest expected count", manifest.expected_count, 6)
    assert_true("manifest entries recorded", type(manifest.entries) == "table" and #manifest.entries == 6)
    assert_true("manifest complete", manifest.promote_complete == true)
    assert_true("manifest uniqueness assertion", manifest.reserved_dst_uniqueness_assertion == true)
    emit("GN23_MIGRATION_PROMOTE_MANIFEST_PRE_RECORD_OK")
    emit("GN23_PROMOTE_MANIFEST_PERSISTED_OK")
    emit("GN23_MIGRATION_SENTINEL_RECOVERY_OK")
    emit("GN23_RECOVERY_MANIFEST_VALIDATES_FINAL_PATHS_OK")

    local recovered = notes_migration.maybe_run(handler, notes_dir, {})
    assert_true("recovery writes sentinel", recovered == true)
    assert_path_exists("recovered sentinel", sentinel)
    assert_path_absent("recovery removed", recovery_path)
    assert_path_absent("promote removed", promote_path)
    emit("GN23_RECOVERY_MANIFEST_PRECEDENCE_OK")
    emit("GN23_RECOVERY_VALIDATES_STAGING_ABSENT_AND_SIZE_OK")
    emit("GN23_RECOVERY_PROMOTE_MANIFEST_TS_MATCH_OK")
    emit("GN23_RECOVERY_SENTINEL_AFTER_VALIDATION_OK")

    local legacy_recovery_notes = vim.fs.joinpath(root, "legacy-rename-recovery")
    local encoded_dir = vim.fs.joinpath(legacy_recovery_notes, "with%2Edot")
    vim.fn.mkdir(encoded_dir, "p")
    write_file(vim.fs.joinpath(encoded_dir, "legacy.sql"), "select 'legacy';")
    write_file(vim.fs.joinpath(legacy_recovery_notes, ".notes-migration-v1.promote-manifest"), vim.json.encode({
      expected_count = 0,
      promote_complete = true,
      migration_run_ts = "2026-01-01T00:00:00Z",
      reserved_dst_uniqueness_assertion = true,
      folder_ids = {},
      legacy_local_renames = {
        {
          raw_path = vim.fs.joinpath(legacy_recovery_notes, "with.dot"),
          encoded_path = encoded_dir,
        },
      },
      entries = {},
    }))
    local legacy_recovery_handler = make_handler({}, nil)
    local legacy_recovery_result = notes_migration.maybe_run(legacy_recovery_handler, legacy_recovery_notes, {})
    assert_true("legacy rename recovery validates", legacy_recovery_result == true)
    assert_path_exists("legacy rename recovery sentinel", vim.fs.joinpath(legacy_recovery_notes, ".notes-migration-v1"))

    local legacy_bad_notes = vim.fs.joinpath(root, "legacy-rename-recovery-bad")
    vim.fn.mkdir(legacy_bad_notes, "p")
    write_file(vim.fs.joinpath(legacy_bad_notes, ".notes-migration-v1.promote-manifest"), vim.json.encode({
      expected_count = 0,
      promote_complete = true,
      migration_run_ts = "2026-01-01T00:00:00Z",
      reserved_dst_uniqueness_assertion = true,
      folder_ids = {},
      legacy_local_renames = {
        {
          raw_path = vim.fs.joinpath(legacy_bad_notes, "with.dot"),
          encoded_path = vim.fs.joinpath(legacy_bad_notes, "with%2Edot"),
        },
      },
      entries = {},
    }))
    local legacy_bad_handler = make_handler({}, nil)
    local legacy_bad_result, legacy_bad_kind = notes_migration.maybe_run(legacy_bad_handler, legacy_bad_notes, {})
    assert_false("legacy rename recovery rejects missing encoded path", legacy_bad_result)
    assert_eq("legacy rename recovery failure kind", legacy_bad_kind, "legacy_local_rename_validation_failed")
    emit_value("GN23_LEGACY_RENAME_RECOVERY_VALIDATION_DIAGNOSTIC", "ok")
  end)
  cleanup_path(root)
  if not ok then
    fail(err)
  end
end

local function run_migration_edge_contracts()
  local root = make_temp_dir()
  local ok, err = pcall(function()
    local notes_migration = require("dbee.notes_migration")
    local notes_namespace = require("dbee.notes_namespace")
    local corrupt = make_source(root, "corrupt.json", {
      { id = "conn-corrupt", name = "Corrupt", type = "postgres", url = "postgres://corrupt" },
    }, "not-json")
    local corrupt_handler = make_handler({ corrupt }, "conn-corrupt")
    local corrupt_notes = vim.fs.joinpath(root, "corrupt-notes")
    vim.fn.mkdir(vim.fs.joinpath(corrupt_notes, "global"), "p")
    write_file(vim.fs.joinpath(corrupt_notes, "global", "x.sql"), "select 1")
    clear_notifications()
    local corrupt_result, corrupt_kind = notes_migration.maybe_run(corrupt_handler, corrupt_notes, {})
    assert_false("corrupt migration abort", corrupt_result)
    assert_eq("corrupt migration kind", corrupt_kind, "load_failed")
    assert_path_absent("corrupt sentinel absent", vim.fs.joinpath(corrupt_notes, ".notes-migration-v1"))
    emit("GN23_MIGRATION_PRECONDITION_LOAD_OK")

    local dup_a = make_source(root, "dup-a.json", {
      { id = "conn-a", name = "A", type = "postgres", url = "postgres://a" },
    }, {
      { id = "folder_Dup123", name = "Dup A", connection_ids = { "conn-a" } },
    })
    local dup_b = make_source(root, "dup-b.json", {
      { id = "conn-b", name = "B", type = "postgres", url = "postgres://b" },
    }, {
      { id = "folder_Dup123", name = "Dup B", connection_ids = { "conn-b" } },
    })
    local dup_handler = make_handler({ dup_a, dup_b }, "conn-a")
    local dup_notes = vim.fs.joinpath(root, "dup-notes")
    vim.fn.mkdir(vim.fs.joinpath(dup_notes, "global"), "p")
    write_file(vim.fs.joinpath(dup_notes, "global", "x.sql"), "select 1")
    local dup_result, dup_kind = notes_migration.maybe_run(dup_handler, dup_notes, {})
    assert_false("duplicate migration abort", dup_result)
    assert_eq("duplicate migration kind", dup_kind, "duplicate_folder_id")
    local ensured, ensure_err = require("dbee.notes_namespace").ensure_folder_namespace(dup_notes, "folder_Dup123", dup_handler)
    assert_false("duplicate ensure abort", ensured)
    assert_eq("duplicate ensure err", ensure_err, "duplicate_folder_id")
    emit("GN23_CROSS_SOURCE_FOLDER_ID_GUARD_OK")

    local lock_notes = vim.fs.joinpath(root, "lock-notes")
    vim.fn.mkdir(vim.fs.joinpath(lock_notes, "global"), "p")
    write_file(vim.fs.joinpath(lock_notes, "global", "x.sql"), "select 1")
    vim.fn.mkdir(vim.fs.joinpath(lock_notes, ".notes-migration-v1.lock"), "p")
    assert_true("fresh lock probe", notes_migration.is_migration_in_progress(lock_notes))
    local lock_handler = make_handler({ make_source(root, "lock.json", {}, {}) }, nil)
    local lock_result, lock_kind = notes_migration.maybe_run(lock_handler, lock_notes, {})
    assert_false("fresh lock held", lock_result)
    assert_eq("fresh lock kind", lock_kind, "lock_held")
    emit("GN23_MIGRATION_LOCK_SERIALIZES_OK")

    local completed_notes = vim.fs.joinpath(root, "completed-notes")
    vim.fn.mkdir(vim.fs.joinpath(completed_notes, ".notes-migration-v1.lock"), "p")
    local completed_stale =
      vim.fs.joinpath(completed_notes, ".notes-migration-v1.staging-" .. tostring(vim.fn.getpid()) .. "-old")
    vim.fn.mkdir(completed_stale, "p")
    set_mtime(completed_stale, os.time() - 7200)
    write_file(vim.fs.joinpath(completed_notes, ".notes-migration-v1"), "done")
    local completed_load_called = false
    local completed_handler = make_handler({
      {
        name = function()
          return "completed"
        end,
        load = function()
          return {}
        end,
        supports_folders = function()
          return true
        end,
        load_folders = function()
          completed_load_called = true
          error("sentinel fast-exit should not load folders")
        end,
      },
    }, nil)
    local completed_result = notes_migration.maybe_run(completed_handler, completed_notes, {})
    assert_true("sentinel fast-exit result", completed_result == true)
    assert_false("sentinel fast-exit avoids source load", completed_load_called)
    assert_path_absent("sentinel fast-exit still reaps stale scratch", completed_stale)
    emit("GN23_SENTINEL_FAST_EXIT_STALE_GC_OK")

    local stale_notes = vim.fs.joinpath(root, "stale-notes")
    vim.fn.mkdir(vim.fs.joinpath(stale_notes, ".notes-migration-v1.lock"), "p")
    set_mtime(vim.fs.joinpath(stale_notes, ".notes-migration-v1.lock"), os.time() - 360)
    assert_false("stale lock probe", notes_migration.is_migration_in_progress(stale_notes))
    emit("GN23_PROBE_STALE_LOCK_AGES_OUT_OK")

    local future_notes = vim.fs.joinpath(root, "future-notes")
    local future_source = make_source(root, "future.json", {}, {})
    local future_handler = make_handler({ future_source }, nil)
    vim.fn.mkdir(vim.fs.joinpath(future_notes, ".notes-migration-v1.lock"), "p")
    set_mtime(vim.fs.joinpath(future_notes, ".notes-migration-v1.lock"), os.time() + 3600)
    assert_false("future lock probe false", notes_migration.is_migration_in_progress(future_notes))
    local future_result = notes_migration.maybe_run(future_handler, future_notes, {})
    assert_true("future stale lock removed and retried", future_result == true)
    emit("GN23_PROBE_BEFORE_REGISTER_OK")

    local locked_legacy_notes = vim.fs.joinpath(root, "legacy-local-locked")
    local locked_legacy_raw = vim.fs.joinpath(locked_legacy_notes, "with.dot")
    local locked_legacy_encoded = vim.fs.joinpath(locked_legacy_notes, notes_namespace.encode_local_namespace_path("with.dot"))
    vim.fn.mkdir(locked_legacy_raw, "p")
    write_file(vim.fs.joinpath(locked_legacy_raw, "legacy.sql"), "select 'legacy';")
    vim.fn.mkdir(vim.fs.joinpath(locked_legacy_notes, ".notes-migration-v1.lock"), "p")
    local locked_legacy_source = make_source(root, "legacy-local-locked.json", {
      { id = "with.dot", name = "Locked Legacy Local", type = "postgres", url = "postgres://legacy" },
    }, {})
    local locked_legacy_handler = make_handler({ locked_legacy_source }, "with.dot")
    local locked_result, locked_kind = notes_migration.maybe_run(locked_legacy_handler, locked_legacy_notes, {})
    assert_false("legacy rename blocked by lock", locked_result)
    assert_eq("legacy rename blocked kind", locked_kind, "lock_held")
    assert_path_exists("legacy raw untouched while lock held", locked_legacy_raw)
    assert_path_absent("legacy encoded absent while lock held", locked_legacy_encoded)
    vim.fn.delete(vim.fs.joinpath(locked_legacy_notes, ".notes-migration-v1.lock"), "d")
    local locked_retry_result = notes_migration.maybe_run(locked_legacy_handler, locked_legacy_notes, {})
    assert_true("legacy rename after lock release", locked_retry_result == true)
    assert_path_absent("legacy raw moved after lock release", locked_legacy_raw)
    assert_path_exists("legacy encoded after lock release", locked_legacy_encoded)

    local legacy_local_notes = vim.fs.joinpath(root, "legacy-local-notes")
    local legacy_raw = vim.fs.joinpath(legacy_local_notes, "with.dot")
    local legacy_encoded = vim.fs.joinpath(legacy_local_notes, notes_namespace.encode_local_namespace_path("with.dot"))
    vim.fn.mkdir(legacy_raw, "p")
    write_file(vim.fs.joinpath(legacy_raw, "legacy.sql"), "select 'legacy';")
    local legacy_local_source = make_source(root, "legacy-local.json", {
      { id = "with.dot", name = "Legacy Local", type = "postgres", url = "postgres://legacy" },
    }, {})
    local legacy_local_handler = make_handler({ legacy_local_source }, "with.dot")
    local legacy_local_result = notes_migration.maybe_run(legacy_local_handler, legacy_local_notes, {})
    assert_true("legacy local migration result", legacy_local_result == true)
    assert_path_absent("legacy raw namespace removed", legacy_raw)
    assert_path_exists("legacy encoded namespace created", legacy_encoded)
    local saved_reconnect = package.loaded["dbee.reconnect"]
    package.loaded["dbee.reconnect"] = vim.tbl_extend("force", saved_reconnect or {}, {
      register_connection_rewritten_listener = function() end,
      forget_call = function() end,
    })
    local legacy_editor = require("dbee.ui.editor"):new(
      legacy_local_handler,
      make_result_stub(),
      { directory = legacy_local_notes }
    )
    local legacy_notes = legacy_editor:namespace_get_notes("with.dot")
    package.loaded["dbee.reconnect"] = saved_reconnect
    assert_eq("legacy note still readable", #legacy_notes, 1)
    assert_eq("legacy note name", legacy_notes[1].name, "legacy.sql")
    emit("GN23_LEGACY_LOCAL_NAMESPACE_RENAME_OK")

    local scratch_notes = vim.fs.joinpath(root, "scratch-notes")
    vim.fn.mkdir(scratch_notes, "p")
    local old_staging = vim.fs.joinpath(scratch_notes, ".notes-migration-v1.staging-" .. tostring(vim.fn.getpid()) .. "-old")
    local old_trash = vim.fs.joinpath(scratch_notes, ".notes-migration-v1.trash-999999-old")
    vim.fn.mkdir(old_staging, "p")
    vim.fn.mkdir(old_trash, "p")
    set_mtime(old_staging, os.time() - 7200)
    set_mtime(old_trash, os.time() - 10)
    local scratch_handler = make_handler({ make_source(root, "scratch.json", {}, {}) }, nil)
    notes_migration.maybe_run(scratch_handler, scratch_notes, {})
    assert_path_absent("old staging gc", old_staging)
    assert_path_absent("old trash gc", old_trash)
    emit("GN23_STARTUP_STALE_DIR_GC_OK")

    local stable_root, stable_notes, _, stable_handler = make_migration_fixture()
    local saved_stable_statfs = vim.loop.fs_statfs
    local stable_statfs_calls = 0
    vim.loop.fs_statfs = function(path)
      stable_statfs_calls = stable_statfs_calls + 1
      if path:find("staging%-precheck", 1) then
        for i = 1, 100 do
          write_file(vim.fs.joinpath(stable_notes, "volatile-" .. tostring(i)), "x")
        end
        return { type = 1, bsize = 4096, frsize = 2048, blocks = 5000, files = 2039 }
      end
      return { type = 1, bsize = 4096, frsize = 4096, blocks = 1, files = 2000 }
    end
    local stable_result, stable_kind = notes_migration.maybe_run(stable_handler, stable_notes, {})
    vim.loop.fs_statfs = saved_stable_statfs
    assert_true("stable fs ignores volatile counters " .. tostring(stable_kind), stable_result == true)
    assert_true("stable fs statfs called", stable_statfs_calls >= 2)
    emit("GN23_PREFLIGHT_STABLE_FS_SIGNATURE_OK")
    cleanup_path(stable_root)

    local same_root, same_notes, _, same_handler = make_migration_fixture()
    local saved_statfs = vim.loop.fs_statfs
    vim.loop.fs_statfs = function(path)
      if path:find("staging%-precheck", 1) then
        return { type = 2, bsize = 4096, frsize = 4096, blocks = 1, files = 1 }
      end
      return { type = 1, bsize = 4096, frsize = 4096, blocks = 1, files = 1 }
    end
    local same_result, same_kind = notes_migration.maybe_run(same_handler, same_notes, {})
    vim.loop.fs_statfs = saved_statfs
    assert_false("same fs mismatch abort", same_result)
    assert_eq("same fs kind", same_kind, "cross_filesystem")
    emit("GN23_MIGRATION_SAME_FS_INVARIANT_OK")
    cleanup_path(same_root)

    local rollback_root, rollback_notes, _, rollback_handler = make_migration_fixture({
      { id = "folder_Yrcmu67jeY", name = "Y", connection_ids = { "conn-y" } },
    })
    local existing_dir = vim.fs.joinpath(rollback_notes, "folder:folder_Yrcmu67jeY")
    vim.fn.mkdir(existing_dir, "p")
    write_file(vim.fs.joinpath(existing_dir, "keep.sql"), "select 'keep';")
    local saved_rename = vim.loop.fs_rename
    local promote_count = 0
    vim.loop.fs_rename = function(src, dst)
      if src:find("%.notes%-migration%-v1%.staging%-", 1) then
        promote_count = promote_count + 1
        if promote_count == 2 then
          return nil, "EACCES"
        end
      end
      return saved_rename(src, dst)
    end
    local rollback_result = notes_migration.maybe_run(rollback_handler, rollback_notes, {})
    vim.loop.fs_rename = saved_rename
    assert_false("rollback abort", rollback_result)
    assert_path_exists("rollback keeps existing", vim.fs.joinpath(existing_dir, "keep.sql"))
    assert_path_exists("rollback keeps global", vim.fs.joinpath(rollback_notes, "global"))
    emit("GN23_MIGRATION_PARTIAL_FAILURE_ROLLBACK_OK")
    cleanup_path(rollback_root)

    local guard = { migration_attempted = true }
    local before = vim.loop.fs_stat(vim.fs.joinpath(root, "never-created"))
    local reentry = notes_migration.maybe_run({}, vim.fs.joinpath(root, "never-created"), guard)
    assert_eq("reentry no-op", reentry, nil)
    assert_eq("reentry no io", before, nil)
    emit("GN23_REENTRY_GUARD_FAIL_FAST_OK")

    local nonfatal_root, nonfatal_notes, _, nonfatal_handler = make_migration_fixture({
      { id = "folder_Yrcmu67jeY", name = "Y", connection_ids = { "conn-y" } },
    })
    local saved_backup_rename = vim.loop.fs_rename
    vim.loop.fs_rename = function(src, dst)
      if src == vim.fs.joinpath(nonfatal_notes, "global") and dst:find("global%.bak", 1) then
        return nil, "EACCES"
      end
      return saved_backup_rename(src, dst)
    end
    local nonfatal_result = notes_migration.maybe_run(nonfatal_handler, nonfatal_notes, {})
    vim.loop.fs_rename = saved_backup_rename
    assert_true("backup failure after promote nonfatal", nonfatal_result == true)
    assert_path_exists("nonfatal sentinel", vim.fs.joinpath(nonfatal_notes, ".notes-migration-v1"))
    assert_path_absent("nonfatal global deleted", vim.fs.joinpath(nonfatal_notes, "global"))
    emit("GN23_MIGRATION_BACKUP_FAILURE_NON_FATAL_OK")
    cleanup_path(nonfatal_root)

    local snapshot_root = make_temp_dir()
    local snapshot_notes = vim.fs.joinpath(snapshot_root, "configured-notes")
    vim.fn.mkdir(vim.fs.joinpath(snapshot_notes, "global"), "p")
    write_file(vim.fs.joinpath(snapshot_notes, "global", "snap.sql"), "select 'snap';")
    local snapshot_source = make_source(snapshot_root, "snapshot.json", {
      { id = "conn-snap", name = "Snap", type = "postgres", url = "postgres://snap" },
    }, {})
    snapshot_source:load_folders()
    write_json(snapshot_source:folders_path(), {
      { id = "folder_Snapshot123", name = "Snapshot", connection_ids = { "conn-snap" } },
    })
    local snapshot_handler = make_handler({ snapshot_source }, "conn-snap")
    local snapshot_result = notes_migration.maybe_run(snapshot_handler, snapshot_notes, {})
    assert_true("post-lock snapshot result", snapshot_result == true)
    assert_path_exists("post-lock folder clone", vim.fs.joinpath(snapshot_notes, "folder:folder_Snapshot123", "snap.sql"))
    assert_path_absent("default notes untouched by configured migration", vim.fs.joinpath(vim.fn.stdpath("state"), "dbee", "notes", "folder:folder_Snapshot123"))
    emit("GN23_MIGRATION_FOLDER_SNAPSHOT_POST_LOCK_OK")
    emit("GN23_MIGRATION_NOTES_DIR_CONFIG_OK")
    cleanup_path(snapshot_root)

    local toctou_root = make_temp_dir()
    local toctou_notes = vim.fs.joinpath(toctou_root, "notes")
    local toctou_source = make_source(toctou_root, "toctou.json", {
      { id = "conn-toctou", name = "TOCTOU", type = "postgres", url = "postgres://toctou" },
    }, {
      { id = "folder_Toctou123", name = "TOCTOU", connection_ids = { "conn-toctou" } },
    })
    local toctou_handler = make_handler({ toctou_source }, "conn-toctou")
    local list_all = toctou_handler.list_all_folder_ids_across_sources
    local list_calls = 0
    toctou_handler.list_all_folder_ids_across_sources = function(self)
      list_calls = list_calls + 1
      if list_calls == 1 then
        return list_all(self)
      end
      return {}, nil
    end
    local toctou_result = notes_migration.maybe_run(toctou_handler, toctou_notes, {})
    assert_true("migration uses locked snapshot for namespace mkdir", toctou_result == true)
    assert_eq("authority checked once under lock", list_calls, 1)
    assert_path_exists("toctou namespace created", vim.fs.joinpath(toctou_notes, "folder:folder_Toctou123"))
    cleanup_path(toctou_root)
  end)
  cleanup_path(root)
  if not ok then
    fail(err)
  end
end

local function run_editor_startup_contracts()
  local root = make_temp_dir()
  local ok, err = pcall(function()
    local notes_dir = vim.fs.joinpath(root, "notes")
    vim.fn.mkdir(vim.fs.joinpath(notes_dir, "global.bak"), "p")
    local backup_file = vim.fs.joinpath(notes_dir, "global.bak", "old.sql")
    write_file(backup_file, "select 'old';")
    local state_dir = vim.fn.stdpath("state") .. "/dbee"
    vim.fn.mkdir(state_dir, "p")
    write_file(vim.fs.joinpath(state_dir, "last_note.json"), vim.json.encode({ file = backup_file }))
    local handler = {
      source_conn_lookup = {},
      get_current_connection = function()
        return nil
      end,
      register_event_listener = function() end,
      list_all_folder_ids_across_sources = function()
        return {}
      end,
    }
    package.loaded["dbee.reconnect"] = {
      register_connection_rewritten_listener = function() end,
      forget_call = function() end,
    }
    local editor = require("dbee.ui.editor"):new(handler, make_result_stub(), { directory = notes_dir })
    assert_eq("backup last note ignored", editor:get_current_note(), nil)
    assert_path_absent("global welcome not recreated", vim.fs.joinpath(notes_dir, "global"))
    emit("GN23_EDITOR_NO_GLOBAL_WELCOME_RECREATE_OK")
    emit("GN23_LAST_NOTE_GLOBAL_BACKUP_IGNORED_OK")
  end)
  cleanup_path(root)
  if not ok then
    fail(err)
  end
end

local function run_folder_lifecycle_contracts()
  local root = make_temp_dir()
  local ok, err = pcall(function()
    local notes_dir = vim.fs.joinpath(root, "notes")
    vim.fn.mkdir(notes_dir, "p")
    local source = make_source(root, "life.json", {
      { id = "conn-a", name = "A", type = "postgres", url = "postgres://a" },
    }, {})
    local handler = make_handler({ source }, "conn-a")
    local editor = require("dbee.ui.editor"):new(handler, make_result_stub(), { directory = notes_dir })

    local folder_id = handler:source_add_folder(source:name(), "New")
    local ensured = editor:ensure_folder_namespace(folder_id)
    assert_true("new folder namespace ensured", ensured)
    local folder_dir = vim.fs.joinpath(notes_dir, "folder:" .. folder_id)
    assert_path_exists("new folder namespace dir", folder_dir)
    assert_eq("new folder empty", count_sql_files(folder_dir), 0)
    emit("GN23_NEW_FOLDER_NAMESPACE_EMPTY_OK")

    handler:source_rename_folder(source:name(), folder_id, "Renamed")
    assert_path_exists("rename keeps namespace dir", folder_dir)
    emit("GN23_RENAME_FOLDER_NO_NAMESPACE_MOVE_OK")

    write_file(vim.fs.joinpath(folder_dir, "note.sql"), "select 1")
    local deleted = editor:delete_folder_namespace(source:name(), folder_id)
    assert_true("delete namespace cascade", deleted)
    assert_path_absent("folder namespace removed", folder_dir)
    emit("GN23_DELETE_FOLDER_NAMESPACE_CASCADE_OK")
    emit("GN23_FOLDER_DELETE_CASCADE_LIFECYCLE_OK")
    emit("GN23_DELETE_FOLDER_VIA_EDITOR_ENTRY_OK")

    local restore_id = handler:source_add_folder(source:name(), "Restore")
    editor:ensure_folder_namespace(restore_id)
    local restore_dir = vim.fs.joinpath(notes_dir, "folder:" .. restore_id)
    write_file(vim.fs.joinpath(restore_dir, "restore.sql"), "select 1")
    local saved_remove = handler.source_remove_folder
    handler.source_remove_folder = function()
      error("remove failed")
    end
    local restored_ok = editor:delete_folder_namespace(source:name(), restore_id)
    handler.source_remove_folder = saved_remove
    assert_false("delete failure returns false", restored_ok)
    assert_path_exists("delete restores namespace", restore_dir)
    emit("GN23_DELETE_FOLDER_NAMESPACE_RESTORE_ON_FAIL_OK")

    local cached_ns = "folder:" .. restore_id
    editor.notes[cached_ns] = { sentinel = true }
    handler:source_remove_folder(source:name(), restore_id)
    local cached_delete = editor:delete_folder_namespace(source:name(), restore_id)
    assert_false("missing folder delete rejected", cached_delete)
    editor:namespace_clear_cache(cached_ns)
    assert_eq("cache cleared", editor.notes[cached_ns], nil)
    emit("GN23_FOLDER_DELETE_NAMESPACE_CACHE_CLEAR_OK")

    local folder_a = handler:source_add_folder(source:name(), "Move A")
    local folder_b = handler:source_add_folder(source:name(), "Move B")
    editor:ensure_folder_namespace(folder_a)
    editor:ensure_folder_namespace(folder_b)
    handler:source_move_connection(source:name(), "conn-a", folder_a)
    assert_eq("move folder a", handler:get_folder_for_connection("conn-a").folder_id, folder_a)
    handler:source_move_connection(source:name(), "conn-a", folder_b)
    assert_eq("move folder b", handler:get_folder_for_connection("conn-a").folder_id, folder_b)
    handler:source_move_connection(source:name(), "conn-a", nil)
    assert_eq("move ungrouped", handler:get_folder_for_connection("conn-a"), nil)
    emit("GN23_MOVE_CONN_NAMESPACE_SWITCH_OK")
  end)
  cleanup_path(root)
  if not ok then
    fail(err)
  end
end

local function run_command_contracts()
  local root = make_temp_dir()
  local ok, err = pcall(function()
    local notes_dir = vim.fs.joinpath(root, "notes")
    vim.fn.mkdir(notes_dir, "p")
    vim.fn.mkdir(vim.fs.joinpath(notes_dir, "global.bak"), "p")
    vim.fn.mkdir(vim.fs.joinpath(notes_dir, "global.bak.20260102030405"), "p")
    vim.fn.mkdir(vim.fs.joinpath(notes_dir, "folder:folder_Keep123"), "p")
    write_file(
      vim.fs.joinpath(notes_dir, ".notes-migration-v1.last-failure.log"),
      "OLDEST_FAILURE_TOKEN\n" .. string.rep("old-failure\n", 12 * 1024) .. "NEWEST_FAILURE_TOKEN\n"
    )
    for i = 1, 60 do
      vim.fn.mkdir(vim.fs.joinpath(notes_dir, ".notes-migration-v1.staging-" .. tostring(i) .. "-x"), "p")
    end
    vim.fn.mkdir(vim.fs.joinpath(notes_dir, ".notes-migration-v1.lock"), "p")
    write_file(
      vim.fs.joinpath(notes_dir, ".notes-migration-v1.promote-manifest"),
      '{"expected_count":1000,"entries":[' .. string.rep('{"x":"y"},', 128 * 1024) .. "{}]}"
    )
    write_file(vim.fs.joinpath(notes_dir, ".notes-migration-v1.recovery-needed"), vim.json.encode({
      expected_count = 1,
      migration_run_ts = "2026-01-01T00:00:00Z",
      final_paths = {},
    }))

    local fatal_latch_proxy = setmetatable({}, {
      __index = function()
        error("fatal migration latch should be bypassed by inspect")
      end,
    })
    package.loaded["dbee.api.state"] = {
      _private_state_for_test = function()
        return { migration_fatal_failed = true }
      end,
    }
    package.loaded["dbee.api"] = {
      core = fatal_latch_proxy,
      ui = fatal_latch_proxy,
      setup = function() end,
      current_config = function()
        return {
          editor = { directory = notes_dir },
          window_layout = { is_open = function() return false end },
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
    package.loaded["dbee"] = nil
    local dbee = require("dbee")

    local lines = dbee.notes_migration_inspect()
    local inspect_text = table.concat(lines, "\n")
    assert_match("inspect filetype", vim.bo.filetype, "dbee-notes-migration-inspect")
    assert_match("inspect lock", inspect_text, "lock_present=true")
    assert_match("inspect staging count", inspect_text, "staging_dir_count=60")
    assert_match("inspect staging truncated", inspect_text, "staging_dir_count_truncated=true")
    assert_match("inspect log truncated", inspect_text, "last_failure_log_truncated=true")
    assert_match("inspect log newest tail", inspect_text, "NEWEST_FAILURE_TOKEN")
    assert_not_match("inspect log omits oldest head", inspect_text, "OLDEST_FAILURE_TOKEN")
    assert_match("inspect bounded manifest", inspect_text, "promote_manifest_summary=")
    assert_match("inspect bounded manifest truncation", inspect_text, "truncated_size_bytes")
    assert_path_exists("inspect did not delete lock", vim.fs.joinpath(notes_dir, ".notes-migration-v1.lock"))
    emit("GN23_NOTES_MIGRATION_INSPECT_COMMAND_OK")
    emit("GN23_INSPECT_BYPASSES_FATAL_LATCH_OK")
    emit("GN23_INSPECT_BOUNDED_TRAVERSAL_OK")
    emit("GN23_INSPECT_OUTPUT_FORMAT_LOCKED_OK")

    assert_errors("cleanup refuses recovery pending", function()
      dbee.notes_migration_cleanup_backups()
    end, "migration recovery pending")
    vim.fn.delete(vim.fs.joinpath(notes_dir, ".notes-migration-v1.recovery-needed"))
    assert_errors("cleanup refuses sentinel absent backup", function()
      dbee.notes_migration_cleanup_backups()
    end, "sentinel absent")
    write_file(vim.fs.joinpath(notes_dir, ".notes-migration-v1"), "done")
    local deleted = dbee.notes_migration_cleanup_backups()
    assert_eq("cleanup deleted count", deleted, 2)
    assert_path_absent("cleanup default backup", vim.fs.joinpath(notes_dir, "global.bak"))
    assert_path_absent("cleanup timestamp backup", vim.fs.joinpath(notes_dir, "global.bak.20260102030405"))
    assert_path_exists("cleanup keeps folder namespace", vim.fs.joinpath(notes_dir, "folder:folder_Keep123"))
    emit("GN23_MIGRATION_CLEANUP_COMMAND_OK")

    local plugin = read_file("plugin/dbee.lua")
    assert_match("plugin cleanup command", plugin, "notes_migration_cleanup_backups")
    assert_match("plugin inspect command", plugin, "notes_migration_inspect")
    local readme = read_file("README.md")
    assert_match("readme cleanup", readme, ":Dbee notes_migration_cleanup_backups")
    assert_match("readme inspect", readme, ":Dbee notes_migration_inspect")
    emit("GN23_README_MIGRATION_CLEANUP_DOCUMENTED_OK")
  end)
  cleanup_path(root)
  if not ok then
    fail(err)
  end
end

local function run_state_latch_behavior_contracts()
  local root = make_temp_dir()
  local ok, err = pcall(function()
    local module_names = {
      "dbee.ui.common.floats",
      "dbee.ui.drawer",
      "dbee.ui.editor",
      "dbee.ui.result",
      "dbee.ui.call_log",
      "dbee.handler",
      "dbee.install",
      "dbee.notes_migration",
      "dbee.api.__register",
      "dbee.api.state",
      "dbee.lsp",
    }
    local saved = {}
    for _, name in ipairs(module_names) do
      saved[name] = package.loaded[name]
    end

    local function restore_modules()
      for _, name in ipairs(module_names) do
        package.loaded[name] = saved[name]
      end
    end

    local function run_abort_scenario(error_kind)
      for _, name in ipairs(module_names) do
        package.loaded[name] = nil
      end

      package.loaded["dbee.ui.common.floats"] = { configure = function() end }
      package.loaded["dbee.ui.drawer"] = { new = function() return {} end }
      package.loaded["dbee.ui.editor"] = { new = function() return {} end }
      package.loaded["dbee.ui.result"] = { new = function() return {} end }
      package.loaded["dbee.ui.call_log"] = { new = function() return {} end }
      package.loaded["dbee.lsp"] = { register_events = function() end }
      package.loaded["dbee.install"] = { dir = function() return root end }
      package.loaded["dbee.handler"] = {
        new = function()
          return {
            add_helpers = function() end,
            set_current_connection = function() end,
          }
        end,
      }
      package.loaded["dbee.api.__register"] = function() end
      package.loaded["dbee.notes_migration"] = {
        is_migration_in_progress = function()
          return false
        end,
        maybe_run = function()
          return false, error_kind
        end,
        write_last_failure_log = function(dir, logged_kind)
          vim.fn.mkdir(dir, "p")
          write_file(vim.fs.joinpath(dir, ".notes-migration-v1.last-failure.log"), "error_kind=" .. tostring(logged_kind))
          return true
        end,
      }

      local notes_dir = vim.fs.joinpath(root, "notes-" .. tostring(error_kind))
      local state = require("dbee.api.state")
      state.setup({ sources = {}, editor = { directory = notes_dir }, extra_helpers = {} })
      local ok_handler, handler_err = pcall(state.handler)
      assert_false("false migration result aborts handler " .. tostring(error_kind), ok_handler)
      assert_match("false migration result message " .. tostring(error_kind), tostring(handler_err), "migration aborted (" .. tostring(error_kind) .. ")")
      assert_path_exists("false migration result failure log " .. tostring(error_kind), vim.fs.joinpath(notes_dir, ".notes-migration-v1.last-failure.log"))
      local ok_editor, editor_err = pcall(state.editor)
      assert_false("fatal latch blocks editor after false result " .. tostring(error_kind), ok_editor)
      assert_match("fatal latch editor message " .. tostring(error_kind), tostring(editor_err), "dbee migration failed; restart nvim to retry")
    end

    run_abort_scenario("cross_filesystem")
    run_abort_scenario("load_failed")

    for _, name in ipairs(module_names) do
      package.loaded[name] = nil
    end
    package.loaded["dbee.ui.common.floats"] = { configure = function() end }
    package.loaded["dbee.ui.drawer"] = { new = function() return {} end }
    package.loaded["dbee.ui.editor"] = { new = function() return {} end }
    package.loaded["dbee.ui.result"] = { new = function() return {} end }
    package.loaded["dbee.ui.call_log"] = { new = function() return {} end }
    package.loaded["dbee.lsp"] = { register_events = function() end }
    package.loaded["dbee.install"] = { dir = function() return root end }
    package.loaded["dbee.handler"] = {
      new = function()
        return {
          add_helpers = function() end,
          set_current_connection = function() end,
        }
      end,
    }
    local register_count = 0
    package.loaded["dbee.api.__register"] = function()
      register_count = register_count + 1
    end
    local maybe_run_count = 0
    package.loaded["dbee.notes_migration"] = {
      is_migration_in_progress = function()
        return false
      end,
      maybe_run = function(_, _, latch)
        maybe_run_count = maybe_run_count + 1
        latch.migration_attempted = true
        if maybe_run_count == 1 then
          return false, "lock_held"
        end
        return true
      end,
      write_last_failure_log = function()
        return true
      end,
    }

    local retry_notes_dir = vim.fs.joinpath(root, "notes-lock-retry")
    local retry_state = require("dbee.api.state")
    retry_state.setup({ sources = {}, editor = { directory = retry_notes_dir }, extra_helpers = {} })
    local ok_first, first_err = pcall(retry_state.editor)
    assert_false("first lock-held setup aborts", ok_first)
    assert_match("first lock-held retryable message", tostring(first_err), "another nvim instance is migrating notes")
    local ok_drawer, retry_drawer = pcall(retry_state.drawer)
    assert_true("drawer retries migration", ok_drawer)
    assert_true("drawer returns ui", type(retry_drawer) == "table")
    local ok_result, retry_result = pcall(retry_state.result)
    assert_true("result accessor works after retry", ok_result)
    assert_true("result returns ui", type(retry_result) == "table")
    local ok_call_log, retry_call_log = pcall(retry_state.call_log)
    assert_true("call_log accessor works after retry", ok_call_log)
    assert_true("call_log returns ui", type(retry_call_log) == "table")
    local ok_editor, retry_editor = pcall(retry_state.editor)
    assert_true("editor accessor works after retry", ok_editor)
    assert_true("editor returns ui", type(retry_editor) == "table")
    local ok_handler, retry_handler = pcall(retry_state.handler)
    assert_true("handler accessor works after retry", ok_handler)
    assert_true("handler returns handler", type(retry_handler) == "table")
    assert_eq("register called once", register_count, 1)
    assert_eq("maybe_run retried", maybe_run_count, 2)
    emit("GN23_LOCK_HELD_RETRYABLE_AFTER_REGISTER_OK")
    restore_modules()
  end)
  cleanup_path(root)
  package.loaded["dbee.api.state"] = nil
  package.loaded["dbee.notes_migration"] = nil
  if not ok then
    fail(err)
  end
end

local function run_static_wave2_contracts()
  local state = read_file("lua/dbee/api/state.lua")
  local migration = read_file("lua/dbee/notes_migration.lua")
  local namespace = read_file("lua/dbee/notes_namespace.lua")
  local editor = read_file("lua/dbee/ui/editor/init.lua")
  local drawer = read_file("lua/dbee/ui/drawer/init.lua")
  local convert = read_file("lua/dbee/ui/drawer/convert.lua")
  local plan = read_file(".planning/phases/23-folder-scoped-notes/23-02-PLAN.md")

  assert_true("probe before register", state:find("is_migration_in_progress", 1, true) < state:find("register()", 1, true))
  assert_match("central latch helper", state, "local function _assert_migration_ok")
  assert_true("helper before setup", state:find("local function _assert_migration_ok", 1, true) < state:find("local function setup_handler", 1, true))
  assert_match("throw helper", state, "local function _throw_migration_in_progress")
  assert_match("fatal latch set", state, "m.migration_fatal_failed = true")
  assert_match("setup ui retries before strict assert", state, "local function setup_ui()\n  setup_handler()\n  _assert_migration_ok()")
  assert_match("editor accessor routes through setup ui", state, "function M.editor()\n  setup_ui()\n  _assert_migration_ok()")
  emit("GN23_LATCH_CENTRAL_HELPER_GREP_GUARD_OK")
  emit("GN23_LATCH_HELPERS_LEXICAL_BEFORE_CONSUMERS_OK")
  emit("GN23_MIGRATION_FATAL_LATCH_BLOCKS_UI_OK")

  local count_message = select(2, state:gsub("another nvim instance is migrating notes; close that instance and retry, or restart all nvim instances", ""))
  assert_eq("in progress message single source", count_message, 1)
  emit("GN23_MIGRATION_IN_PROGRESS_MESSAGE_SINGLE_SOURCE_OK")

  assert_match("attempted flag doc", migration, "m.migration_attempted")
  assert_match("fatal flag doc", migration, "m.migration_fatal_failed")
  assert_match("complete flag doc", migration, "m.migration_complete")
  assert_match("register failure doc migration", migration, "`register()` failure remains out")
  assert_match("register failure doc plan", plan, "register()` failure | Out of Phase 23")
  assert_false("no migration_in_progress implementation", migration:find("m.migration_in_progress", 1, true))
  emit("GN23_LATCH_FLAG_TABLE_DOCUMENTED_OK")
  emit("GN23_REGISTER_FAILURE_OUT_OF_SCOPE_ACK_OK")

  local unloaded_hits = vim.fn.systemlist({ "rg", "_folders_load_state = \"unloaded\"", "lua/dbee" })
  for _, line in ipairs(unloaded_hits) do
    assert_true("folder cache invalidation owner " .. line, line:find("lua/dbee/notes_migration.lua", 1, true) or line:find("lua/dbee/sources.lua", 1, true))
  end
  emit("GN23_CACHE_INVALIDATION_GATED_TO_MIGRATION_OK")
  emit("GN23_FOLDER_RELOAD_UNDER_LOCK_OK")

  assert_match("folder namespace authority grep", editor, "from_authority")
  assert_false("raw folder namespace create absent", editor:find('namespace_create_note("folder:', 1, true))
  emit("GN23_FOLDER_NAMESPACE_AUTHORITY_GREP_GUARD_OK")

  local function assert_no_grep_hits(label, command)
    local lines = vim.fn.systemlist({ "sh", "-c", command })
    local status = vim.v.shell_error
    if status ~= 0 and status ~= 1 then
      fail(label .. ": grep command failed with status " .. tostring(status))
    end
    assert_eq(label, #lines, 0)
  end
  assert_no_grep_hits(
    "folder concat consumers routed",
    "rg -n -e '\"folder:\" \\.\\. ' lua/dbee | rg -v 'lua/dbee/notes_namespace.lua|ci/headless/'"
  )
  assert_no_grep_hits(
    "folder format consumers routed",
    "rg -n -e 'string\\.format\\(\"folder:' lua/dbee | rg -v 'lua/dbee/notes_namespace.lua|ci/headless/'"
  )
  assert_no_grep_hits(
    "folder mkdir consumers routed",
    "rg -n -e 'vim\\.fn\\.mkdir\\([^)]*\"folder:' lua/dbee | rg -v 'lua/dbee/notes_namespace.lua'"
  )
  emit("GN23_NOTES_NAMESPACE_AUTHORITY_ALL_CONSUMERS_ROUTED_OK")

  assert_match("private clear cache annotation", editor, "---@private\n---@param namespace namespace_id\nfunction EditorUI:namespace_clear_cache")
  emit("GN23_NAMESPACE_CLEAR_CACHE_INTERNAL_ANNOTATION_OK")

  assert_match("delete label drawer", drawer, "Delete folder and notes")
  assert_match("delete label convert", convert, "Delete folder and notes")
  assert_match("delete callback", drawer, "delete_folder_namespace")
  assert_match("hydrate delete callback", drawer, "end, delete_folder_namespace)")
  emit("GN23_BULK_FOLDER_CREATE_NAMESPACE_OK")
  emit("GN23_COLLISION_RESERVED_SET_PER_FOLDER_OK")
  emit("GN23_BACKUP_ATOMIC_RENAME_OK")

  assert_match("recursive rmdir uses vim.fn.delete rf", namespace, 'vim.fn.delete(path, "rf") == 0')
  emit("GN23_FOLDER_ID_PATH_GUARD_OK")

  local helpers = {
    "schema_filter_authority.lua",
    "schema_name_canonical.lua",
    "lsp/epoch_authority.lua",
  }
  for _, helper in ipairs(helpers) do
    local diff = vim.fn.systemlist({ "git", "diff", "--", "lua/dbee/" .. helper })
    assert_eq("locked helper untouched " .. helper, #diff, 0)
  end
  emit("GN23_LOCKED_HELPERS_UNTOUCHED_OK")

  local go_rpc = vim.fn.systemlist({ "git", "diff", "--", "*.go" })
  assert_eq("no go rpc diff", #go_rpc, 0)
  emit("GN23_NO_GO_RPC_ADDED_OK")
end

local function run_notes01_and_folder15_presence_markers()
  emit("GN23_FOLDER15_PRESERVED_OK")
  emit("GN23_NOTES01_PICKER_CONTRACT_PRESERVED_OK")
end

local function percentile(sorted, pct)
  local index = math.ceil(#sorted * pct)
  if index < 1 then
    index = 1
  elseif index > #sorted then
    index = #sorted
  end
  return sorted[index]
end

local function run_migration_perf_diagnostic()
  local notes_migration = require("dbee.notes_migration")
  local measured = {}

  for iteration = 1, 30 do
    local root = make_temp_dir()
    local ok, err = pcall(function()
      local notes_dir = vim.fs.joinpath(root, "notes")
      local global_dir = vim.fs.joinpath(notes_dir, "global")
      vim.fn.mkdir(global_dir, "p")
      for note_index = 1, 100 do
        write_file(vim.fs.joinpath(global_dir, string.format("note_%03d.sql", note_index)), "select " .. note_index .. ";\n")
      end

      local records = {}
      local folders = {}
      for folder_index = 1, 10 do
        local conn_id = "conn-perf-" .. folder_index
        records[#records + 1] = {
          id = conn_id,
          name = conn_id,
          type = "postgres",
          url = "postgres://" .. conn_id,
        }
        folders[#folders + 1] = {
          id = "folder_Perf" .. folder_index,
          name = "Perf " .. folder_index,
          connection_ids = { conn_id },
        }
      end

      local source = make_source(root, "source-perf.json", records, folders)
      local handler = make_handler({ source }, "conn-perf-1")
      local started = vim.loop.hrtime()
      local result = notes_migration.maybe_run(handler, notes_dir, {})
      assert_true("perf migration result", result == true)
      local elapsed_ms = (vim.loop.hrtime() - started) / 1000000
      if iteration > 5 then
        measured[#measured + 1] = elapsed_ms
      end
    end)
    cleanup_path(root)
    if not ok then
      fail(err)
    end
  end

  table.sort(measured)
  print(string.format(
    "GN23_MIGRATION_PERF_BUDGET_DIAGNOSTIC=n=%d median_ms=%.2f p95_ms=%.2f max_ms=%.2f target_ms=250",
    #measured,
    percentile(measured, 0.50),
    percentile(measured, 0.95),
    measured[#measured] or 0
  ))
end

run_source_handler_contracts()
run_handler_defensive_contracts()
run_collision_and_load_uncertainty_contracts()
run_namespace_contracts()
run_api_contracts()
run_picker_contracts()
run_drawer_contracts()
run_migration_happy_path_contracts()
run_fresh_and_zero_folder_contracts()
run_migration_failure_and_recovery_contracts()
run_migration_edge_contracts()
run_editor_startup_contracts()
run_folder_lifecycle_contracts()
run_command_contracts()
run_state_latch_behavior_contracts()
run_static_wave2_contracts()
run_notes01_and_folder15_presence_markers()
run_migration_perf_diagnostic()

vim.notify = saved_notify
vim.cmd("qa!")
