-- Headless validation for Phase 8 type-aware connection wizard flow,
-- transient-spec ping gating, and drawer integration seams.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_connection_wizard.lua"

local Harness = dofile(vim.fn.getcwd() .. "/ci/headless/phase7_harness.lua")

local function fail(msg)
  print("DCFG02_WIZARD_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. vim.inspect(value))
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local function assert_match(label, actual, pattern)
  if type(actual) ~= "string" or actual:find(pattern, 1, true) == nil then
    fail(label .. ": expected " .. vim.inspect(actual) .. " to contain " .. vim.inspect(pattern))
  end
end

local function contains(list, wanted)
  for _, item in ipairs(list or {}) do
    if item == wanted then
      return true
    end
  end
  return false
end

local function find_record(records, wanted_id)
  for _, record in ipairs(records or {}) do
    if record.id == wanted_id then
      return record
    end
  end
  return nil
end

local function find_record_by_name(records, wanted_name)
  for _, record in ipairs(records or {}) do
    if record.name == wanted_name then
      return record
    end
  end
  return nil
end

local function last(list)
  return list[#list]
end

local function index_of(list, wanted)
  for index, item in ipairs(list or {}) do
    if item == wanted then
      return index
    end
  end
  return nil
end

local function read_file(path)
  local fd = assert(io.open(path, "r"))
  local content = fd:read("*a")
  fd:close()
  return content
end

local function write_json(path, records)
  local ok, encoded = pcall(vim.fn.json_encode, records)
  if not ok then
    fail("json encode failed for " .. tostring(path))
  end
  local fd = assert(io.open(path, "w"))
  fd:write(encoded)
  fd:close()
end

local function read_json(path)
  local content = read_file(path)
  if content == "" then
    return {}
  end
  local ok, decoded = pcall(vim.fn.json_decode, content)
  if not ok then
    fail("json decode failed for " .. tostring(path))
  end
  return decoded or {}
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

local function create_wallet_fixture(base_dir, contents, as_zip)
  local wallet_dir = vim.fs.joinpath(base_dir, "wallet_" .. tostring(math.random(1000, 9999)))
  vim.fn.mkdir(wallet_dir, "p")
  local tns_path = vim.fs.joinpath(wallet_dir, "tnsnames.ora")
  if contents ~= nil then
    local fd = assert(io.open(tns_path, "w"))
    fd:write(contents)
    fd:close()
  end

  if not as_zip then
    return wallet_dir
  end

  local zip_path = wallet_dir .. ".zip"
  local ok = false
  if vim.fn.executable("zip") == 1 then
    vim.fn.system({ "zip", "-jq", zip_path, tns_path })
    ok = vim.v.shell_error == 0
  elseif vim.fn.executable("python3") == 1 then
    local script = table.concat({
      "import sys, zipfile",
      "zip_path, tns_path = sys.argv[1], sys.argv[2]",
      "with zipfile.ZipFile(zip_path, 'w') as zf:",
      "    zf.write(tns_path, 'tnsnames.ora')",
    }, "\n")
    vim.fn.system({ "python3", "-c", script, zip_path, tns_path })
    ok = vim.v.shell_error == 0
  end

  if not ok then
    fail("failed creating wallet zip fixture")
  end
  return zip_path
end

local ROOT_STRUCTURES = {
  {
    type = "schema",
    name = "public",
    schema = "public",
    children = {
      { type = "table", name = "users", schema = "public" },
      { type = "view", name = "users_view", schema = "public" },
    },
  },
}

local DEFAULT_MAPPINGS = {
  { key = "<CR>", mode = "n", action = "action_1" },
  { key = "cw", mode = "n", action = "action_2" },
  { key = "dd", mode = "n", action = "action_3" },
  { key = "a", mode = "n", action = "add_connection" },
  { key = "e", mode = "n", action = "edit_connection" },
  { key = "/", mode = "n", action = "filter" },
  { key = "R", mode = "n", action = "refresh" },
}

local UX13_WIZARD_WINHIGHLIGHT =
  "Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle,CursorLine:Visual,Search:IncSearch"

local saved_notify = vim.notify
local notifications = {}

vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = {
    msg = tostring(msg),
    level = level,
    opts = opts,
  }
end

local function install_nui_stubs(runtime)
  local function new_popup(opts, hooks)
    local popup = {
      opts = opts or {},
      hooks = hooks or {},
      maps = {},
      bufnr = nil,
      winid = nil,
    }

    function popup:mount()
      if self.winid and vim.api.nvim_win_is_valid(self.winid) then
        return
      end

      self.bufnr = vim.api.nvim_create_buf(false, true)
      local size = self.opts.size or {}
      local width = type(size) == "table" and (size.width or size[1]) or size or 60
      local height = type(size) == "table" and (size.height or size[2]) or size or 12

      local config = {
        relative = "editor",
        row = 1,
        col = 1,
        width = width,
        height = height,
        style = "minimal",
        border = "single",
      }

      local relative = self.opts.relative
      if type(relative) == "table" and relative.type == "win" and vim.api.nvim_win_is_valid(relative.winid) then
        config.relative = "win"
        config.win = relative.winid
        local position = self.opts.position
        if type(position) == "table" then
          config.row = position.row or 1
          config.col = position.col or 1
        end
      end

      self.winid = vim.api.nvim_open_win(self.bufnr, true, config)
      runtime.active_popups[#runtime.active_popups + 1] = self
    end

    function popup:unmount()
      if self.hooks.on_close then
        self.hooks.on_close()
      end
      if self.winid and vim.api.nvim_win_is_valid(self.winid) then
        pcall(vim.api.nvim_win_close, self.winid, true)
      end
      if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
        pcall(vim.api.nvim_buf_delete, self.bufnr, { force = true })
      end
      self.winid = nil
      self.bufnr = nil
    end

    function popup:map(mode, lhs, rhs)
      self.maps[(mode or "n") .. ":" .. tostring(lhs)] = rhs
    end

    return popup
  end

  package.loaded["nui.popup"] = function(opts)
    return new_popup(opts, {})
  end

  package.loaded["nui.input"] = function(opts, input_opts)
    local input = new_popup(opts, {
      on_close = function()
        if input_opts and input_opts.on_close then
          input_opts.on_close()
        end
      end,
    })
    input.input_opts = input_opts or {}
    function input:submit(value)
      if self.input_opts.on_submit then
        self.input_opts.on_submit(value)
      end
    end
    return input
  end
end

local function install_dbee_functions(runtime)
  local events = require("dbee.handler.__events")

  vim.fn.DbeeDeleteConnection = function(conn_id)
    runtime.connections[conn_id] = nil
  end

  vim.fn.DbeeCreateConnection = function(spec, create_opts)
    local copy = {
      id = spec.id,
      name = spec.name,
      type = spec.type,
      url = spec.url,
    }
    runtime.connections[copy.id] = copy
    runtime.created_connections[#runtime.created_connections + 1] = copy
    if runtime.current_conn_id == nil and not (create_opts and create_opts.preserve_nil_current == true) then
      runtime.current_conn_id = copy.id
      events.trigger("current_connection_changed", {
        conn_id = copy.id,
        cleared = false,
      })
    end
    return copy.id
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
    if runtime.current_conn_id == conn_id then
      return
    end
    runtime.current_conn_id = conn_id
    events.trigger("current_connection_changed", {
      conn_id = conn_id,
      cleared = false,
    })
  end

  vim.fn.DbeeClearCurrentConnection = function()
    if runtime.current_conn_id == nil then
      return
    end
    runtime.current_conn_id = nil
    events.trigger("current_connection_changed", {
      conn_id = vim.NIL,
      cleared = true,
    })
  end

  vim.fn.DbeeConnectionGetParams = function(conn_id)
    if runtime.connections[conn_id] then
      return vim.deepcopy(runtime.connections[conn_id])
    end
    return vim.NIL
  end

  vim.fn.DbeeConnectionGetHelpers = function()
    return {}
  end

  vim.fn.DbeeConnectionExecute = function(conn_id, query)
    runtime.executed_queries[#runtime.executed_queries + 1] = {
      conn_id = conn_id,
      query = query,
    }
    return {
      id = "call-" .. tostring(#runtime.executed_queries),
      query = query,
      state = "archived",
    }
  end

  vim.fn.DbeeConnectionGetCalls = function()
    return {}
  end

  vim.fn.DbeeConnectionGetStructure = function()
    return {}
  end

  vim.fn.DbeeConnectionGetStructureAsync = function(conn_id, request_id, root_epoch, caller_token)
    runtime.structure_requests[#runtime.structure_requests + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      root_epoch = root_epoch,
      caller_token = caller_token,
    }
  end

  vim.fn.DbeeConnectionGetColumns = function()
    return {}
  end

  vim.fn.DbeeConnectionGetColumnsAsync = function(conn_id, request_id, branch_id, root_epoch, opts)
    runtime.column_requests[#runtime.column_requests + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = root_epoch,
      opts = vim.deepcopy(opts or {}),
    }
  end

  vim.fn.DbeeConnectionListDatabases = function()
    return { "", {} }
  end

  vim.fn.DbeeConnectionListDatabasesAsync = function(conn_id, request_id, root_epoch)
    runtime.database_requests[#runtime.database_requests + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      root_epoch = root_epoch,
    }
  end

  vim.fn.DbeeConnectionSelectDatabase = function() end

  vim.fn.DbeeConnectionTest = function()
    return vim.NIL
  end

  vim.fn.DbeeConnectionTestSpec = function(params)
    runtime.connection_test_spec_calls[#runtime.connection_test_spec_calls + 1] = vim.deepcopy(params)
    runtime.call_order[#runtime.call_order + 1] = "ping"
    if type(runtime.connection_test_spec_failure) == "function" then
      local failure = runtime.connection_test_spec_failure(vim.deepcopy(params))
      if failure then
        return vim.deepcopy(failure)
      end
      return vim.NIL
    end
    if runtime.connection_test_spec_failure then
      local failure = runtime.connection_test_spec_failure
      runtime.connection_test_spec_failure = nil
      return vim.deepcopy(failure)
    end
    return vim.NIL
  end
end

local function wrap_filesource(source, runtime)
  local original_create = source.create
  local original_update = source.update
  local original_load = source.load

  source.create_calls = {}
  source.update_calls = {}
  source.load_calls = 0

  function source:create(details)
    self.create_calls[#self.create_calls + 1] = vim.deepcopy(details)
    runtime.call_order[#runtime.call_order + 1] = "file:create"
    return original_create(self, details)
  end

  function source:update(conn_id, details)
    self.update_calls[#self.update_calls + 1] = {
      conn_id = conn_id,
      details = vim.deepcopy(details),
    }
    runtime.call_order[#runtime.call_order + 1] = "file:update"
    return original_update(self, conn_id, details)
  end

  function source:load()
    self.load_calls = self.load_calls + 1
    runtime.call_order[#runtime.call_order + 1] = "file:load"
    if self.fail_next_load then
      local err = self.fail_next_load
      self.fail_next_load = nil
      error(err)
    end
    return original_load(self)
  end

  return source
end

local function new_raw_source(name, specs, runtime)
  local source = {
    _name = name,
    _specs = vim.deepcopy(specs or {}),
    create_calls = {},
    update_calls = {},
    delete_calls = {},
  }

  function source:name()
    return self._name
  end

  function source:load()
    return vim.deepcopy(self._specs)
  end

  function source:create(details)
    self.create_calls[#self.create_calls + 1] = vim.deepcopy(details)
    runtime.call_order[#runtime.call_order + 1] = "raw:create"
    local spec = {
      id = details.id or ("raw-created-" .. tostring(#self._specs + 1)),
      name = details.name,
      type = details.type,
      url = details.url,
    }
    self._specs[#self._specs + 1] = spec
    return spec.id
  end

  function source:update(conn_id, details)
    self.update_calls[#self.update_calls + 1] = {
      conn_id = conn_id,
      details = vim.deepcopy(details),
    }
    runtime.call_order[#runtime.call_order + 1] = "raw:update"
    for _, spec in ipairs(self._specs) do
      if spec.id == conn_id then
        spec.name = details.name
        spec.type = details.type
        spec.url = details.url
        return
      end
    end
    error("missing raw connection: " .. tostring(conn_id))
  end

  function source:delete(conn_id)
    self.delete_calls[#self.delete_calls + 1] = conn_id
    for index, spec in ipairs(self._specs) do
      if spec.id == conn_id then
        table.remove(self._specs, index)
        return
      end
    end
    error("missing raw connection: " .. tostring(conn_id))
  end

  return source
end

local function build_source_meta(source)
  local meta = {
    id = source:name(),
    name = source:name(),
    can_create = type(source.create) == "function",
    can_update = type(source.update) == "function",
    can_delete = type(source.delete) == "function",
    file = nil,
  }

  if type(source.file) == "function" then
    local ok, path_or_err = pcall(source.file, source)
    if ok then
      meta.file = path_or_err
    else
      fail("build_source_meta failed: " .. tostring(path_or_err))
    end
  end

  return meta
end

local function default_file_records()
  return {
    {
      id = "conn-meta",
      name = "Meta PG",
      type = "postgres",
      url = "postgres://meta_user:meta_pass@meta-host:5432/meta_db?sslmode=require",
      wizard = {
        db_kind = "postgres",
        mode = "postgres_url",
        fields = {
          name = "Meta PG",
          url = "postgres://meta_user:meta_pass@meta-host:5432/meta_db?sslmode=require",
        },
      },
    },
    {
      id = "conn-form",
      name = "Form PG",
      type = "postgres",
      url = "postgres://form_user:form_pass@form-host:5432/form_db?sslmode=require",
    },
    {
      id = "conn-unsupported",
      name = "Unsupported PG",
      type = "postgres",
      url = "postgres://raw_user:raw_pass@raw-host:5432/raw_db?sslmode=require&application_name=nvim-dbee",
    },
  }
end

local function default_raw_records()
  return {
    {
      id = "raw-mysql",
      name = "Raw MySQL",
      type = "mysql",
      url = "mysql://root@localhost/sample",
    },
  }
end

local function new_env(opts)
  opts = opts or {}

  Harness.reset_modules({
    "dbee.utils",
    "dbee.handler.__events",
    "dbee.handler",
    "dbee.sources",
    "dbee.ui.drawer",
    "dbee.ui.drawer.convert",
    "dbee.ui.drawer.model",
    "dbee.ui.connection_wizard",
    "dbee.reconnect",
    "nui.popup",
    "nui.input",
  })

  local runtime = {
    active_popups = {},
    prompt_calls = {},
    editor_calls = {},
    select_calls = {},
    input_calls = {},
    filter_sessions = {},
    connections = {},
    current_conn_id = nil,
    connection_test_spec_calls = {},
    connection_invalidated_events = {},
    source_reload_failed_events = {},
    current_connection_changed_events = {},
    created_connections = {},
    structure_requests = {},
    column_requests = {},
    database_requests = {},
    executed_queries = {},
    call_order = {},
    next_prompt_response = nil,
    next_select_choice = nil,
    next_input_value = nil,
    last_wizard = nil,
    last_wizard_open = nil,
  }

  Harness.install_ui_stubs(runtime, {
    stub_reconnect = true,
  })
  install_nui_stubs(runtime)
  install_dbee_functions(runtime)

  local dir = make_temp_dir()
  local file_path = vim.fs.joinpath(dir, "phase8_connections.json")
  write_json(file_path, vim.deepcopy(opts.file_records or default_file_records()))

  local sources = {}
  local Sources = require("dbee.sources")
  local file_source = nil
  if opts.include_file_source ~= false then
    file_source = wrap_filesource(Sources.FileSource:new(file_path), runtime)
    sources[#sources + 1] = file_source
  end

  local raw_source = nil
  if opts.include_raw_source ~= false then
    raw_source = new_raw_source(opts.raw_source_name or "raw-source", opts.raw_records or default_raw_records(), runtime)
    sources[#sources + 1] = raw_source
  end

  local Handler = require("dbee.handler")
  local DrawerUI = require("dbee.ui.drawer")
  local convert = require("dbee.ui.drawer.convert")
  local connection_wizard = require("dbee.ui.connection_wizard")

  local original_open = connection_wizard.open
  connection_wizard.open = function(open_opts)
    local wizard = original_open(open_opts)
    runtime.last_wizard = wizard
    runtime.last_wizard_open = {
      source_id = open_opts.source_meta and open_opts.source_meta.id or nil,
      mode = open_opts.mode,
      title = open_opts.title,
      seed = vim.deepcopy(open_opts.seed),
    }
    return wizard
  end

  local handler = Handler:new(sources)
  Harness.drain()

  if opts.current_conn_id ~= nil then
    if opts.current_conn_id == false then
      vim.fn.DbeeClearCurrentConnection()
    else
      vim.fn.DbeeSetCurrentConnection(opts.current_conn_id)
    end
  end

  local editor = {
    register_event_listener = function() end,
    get_current_note = function()
      return { id = "note-1" }
    end,
    namespace_get_notes = function()
      return {}
    end,
    set_current_note = function() end,
    namespace_create_note = function()
      return "note-created"
    end,
    note_rename = function() end,
    namespace_remove_note = function() end,
    search_note = function()
      return nil
    end,
  }

  local result = {
    set_call = function(_, call)
      runtime.last_result_call = call
    end,
  }

  local drawer = DrawerUI:new(handler, editor, result, {
    mappings = vim.deepcopy(DEFAULT_MAPPINGS),
  })

  handler:register_event_listener("connection_invalidated", function(data)
    runtime.connection_invalidated_events[#runtime.connection_invalidated_events + 1] = vim.deepcopy(data)
  end)
  handler:register_event_listener("source_reload_failed", function(data)
    runtime.source_reload_failed_events[#runtime.source_reload_failed_events + 1] = vim.deepcopy(data)
  end)
  handler:register_event_listener("current_connection_changed", function(data)
    runtime.current_connection_changed_events[#runtime.current_connection_changed_events + 1] = vim.deepcopy(data)
  end)

  local host_buf, winid = Harness.with_window()
  drawer:show(winid)
  Harness.drain()

  if opts.seed_root_conn_ids then
    for _, conn_id in ipairs(opts.seed_root_conn_ids) do
      drawer._struct_cache.root[conn_id] = {
        structures = vim.deepcopy(ROOT_STRUCTURES),
      }
      drawer._struct_cache.root_epoch[conn_id] = handler:get_authoritative_root_epoch(conn_id)
    end
    drawer:refresh()
    Harness.drain()
  end

  local env = {
    runtime = runtime,
    temp_dir = dir,
    file_path = file_path,
    file_source = file_source,
    raw_source = raw_source,
    handler = handler,
    drawer = drawer,
    convert = convert,
    connection_wizard = connection_wizard,
    host_buf = host_buf,
    winid = winid,
  }

  function env:file_source_meta()
    return build_source_meta(assert(self.file_source))
  end

  function env:raw_source_meta()
    return build_source_meta(assert(self.raw_source))
  end

  function env:cleanup()
    if self.drawer and self.drawer.dispose then
      pcall(self.drawer.dispose, self.drawer)
    elseif self.drawer and self.drawer.prepare_close then
      pcall(self.drawer.prepare_close, self.drawer)
    end
    for _, popup in ipairs(self.runtime.active_popups or {}) do
      if popup and popup.unmount then
        pcall(popup.unmount, popup)
      end
    end
    if self.drawer and self.drawer.bufnr and vim.api.nvim_buf_is_valid(self.drawer.bufnr) then
      pcall(vim.api.nvim_buf_delete, self.drawer.bufnr, { force = true })
    end
    Harness.close_window_and_buffer(self.host_buf, self.winid)
    cleanup_path(self.temp_dir)
  end

  return env
end

local function clear_runtime_observations(runtime)
  runtime.connection_test_spec_calls = {}
  runtime.connection_invalidated_events = {}
  runtime.source_reload_failed_events = {}
  runtime.current_connection_changed_events = {}
  runtime.call_order = {}
  if runtime.last_wizard and runtime.last_wizard.close then
    pcall(runtime.last_wizard.close, runtime.last_wizard)
  end
  runtime.last_wizard = nil
  runtime.last_wizard_open = nil
end

local function latest_connection_invalidated(runtime, reason)
  for index = #runtime.connection_invalidated_events, 1, -1 do
    local item = runtime.connection_invalidated_events[index]
    if reason == nil or item.reason == reason then
      return item
    end
  end
  return nil
end

local function latest_source_reload_failed(runtime, reason)
  for index = #runtime.source_reload_failed_events, 1, -1 do
    local item = runtime.source_reload_failed_events[index]
    if reason == nil or item.reason == reason then
      return item
    end
  end
  return nil
end

local function expect_wizard(env, action)
  env.runtime.last_wizard = nil
  env.runtime.last_wizard_open = nil
  action()
  Harness.drain()
  assert_true("wizard opened", env.runtime.last_wizard ~= nil)
  return env.runtime.last_wizard
end

local function assert_winhighlight(label, opts)
  assert_eq(label, opts and opts.win_options and opts.win_options.winhighlight, UX13_WIZARD_WINHIGHLIGHT)
end

local function assert_buffer_contains(label, bufnr, expected)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  assert_match(label, table.concat(lines, "\n"), expected)
end

local function submit_and_assert_success(wizard)
  local submission = wizard:submit()
  Harness.drain()
  assert_true("wizard submission succeeded", submission ~= nil)
  return submission
end

local function run_navigation_and_seed_contracts()
  local env = new_env({
    current_conn_id = "conn-meta",
    seed_root_conn_ids = { "conn-meta" },
  })

  local file_source_meta = env:file_source_meta()
  local raw_source_meta = env:raw_source_meta()

  do
    local original_get_node = env.drawer.tree.get_node
    env.drawer.tree.get_node = function()
      return nil
    end
    env.runtime.next_select_choice = raw_source_meta.name
    local wizard = expect_wizard(env, function()
      env.drawer:get_actions().add_connection()
    end)
    env.drawer.tree.get_node = original_get_node
    assert_eq("source picker source id", env.runtime.last_wizard_open.source_id, raw_source_meta.id)
    local picker_call = last(env.runtime.select_calls)
    assert_eq("source picker title", picker_call.title, "Select a source")
    assert_true("source picker includes filesource", contains(picker_call.items, file_source_meta.name))
    assert_true("source picker includes raw source", contains(picker_call.items, raw_source_meta.name))
    wizard:close()
    print("DCFG02_SOURCE_PICKER_OK=true")
  end

  do
    Harness.set_current_node(env.winid, env.drawer.tree, "conn-meta")
    env.runtime.next_select_choice = "Edit connection"
    local wizard = expect_wizard(env, function()
      env.drawer:get_actions().edit_connection()
    end)
    assert_eq("metadata seed mode", wizard.state.mode, "postgres_url")
    assert_eq("metadata seed url", wizard:current_fields().url, "postgres://meta_user:meta_pass@meta-host:5432/meta_db?sslmode=require")
    wizard:close()
    print("DCFG02_EDIT_SEED_METADATA_OK=true")
  end

  do
    local wizard = expect_wizard(env, function()
      env.drawer:open_edit_connection_with_wizard(file_source_meta, "conn-form")
    end)
    assert_eq("parse fallback mode", wizard.state.mode, "postgres_form")
    assert_eq("parse fallback host", wizard:current_fields().host, "form-host")
    assert_eq("parse fallback database", wizard:current_fields().database, "form_db")
    wizard:close()
    print("DCFG02_EDIT_PARSE_FALLBACK_OK=true")
  end

  do
    local wizard = expect_wizard(env, function()
      env.drawer:open_edit_connection_with_wizard(file_source_meta, "conn-unsupported")
    end)
    assert_eq("unsupported postgres mode", wizard.state.mode, "postgres_url")
    assert_true("unsupported postgres raw fallback", wizard.state.raw_fallback == true)
    wizard:close()
    print("DCFG02_PG_URL_UNSUPPORTED_FALLBACK_OK=true")
  end

  do
    local wizard = expect_wizard(env, function()
      env.drawer:open_edit_connection_with_wizard(raw_source_meta, "raw-mysql")
    end)
    assert_eq("other fallback mode", wizard.state.mode, "other_raw")
    assert_true("other fallback raw", wizard.state.raw_fallback == true)
    wizard:close()
    print("DCFG02_OTHER_FALLBACK_OK=true")
  end

  do
    local wizard = env.connection_wizard.open({
      title = "Mode Flow",
      seed = {
        params = {
          name = "",
          type = "",
          url = "",
        },
      },
    })
    assert_eq("default wizard mode", wizard.state.mode, "postgres_url")
    local total_modes = 0
    for _, options in pairs(env.connection_wizard._MODE_OPTIONS or {}) do
      total_modes = total_modes + #options
    end
    assert_eq("total modes", total_modes, 5)
    wizard:set_db_kind("oracle")
    assert_eq("oracle default mode", wizard.state.mode, "oracle_cloud_wallet")
    wizard:set_mode("oracle_custom_jdbc")
    assert_eq("oracle custom jdbc mode", wizard.state.mode, "oracle_custom_jdbc")
    wizard:set_db_kind("postgres")
    assert_eq("postgres default mode", wizard.state.mode, "postgres_url")
    wizard:set_mode("postgres_form")
    assert_eq("postgres form mode", wizard.state.mode, "postgres_form")
    assert_eq("postgres form default port", wizard:current_fields().port, "5432")
    wizard:set_db_kind("other")
    assert_eq("other default mode", wizard.state.mode, "other_raw")
    wizard:close()
    print("DCFG02_MODE_FLOW_OK=true")
  end

  do
    local wallet_contents = table.concat({
      "ALPHA_LOW = (DESCRIPTION=",
      "  (ADDRESS=(PROTOCOL=tcps)(HOST=db.example.com)(PORT=1522))",
      "  (CONNECT_DATA=(SERVICE_NAME=alpha_low))",
      ")",
      "BETA = (DESCRIPTION=(ADDRESS=(PROTOCOL=tcps)(HOST=db.example.com)(PORT=1522))(CONNECT_DATA=(SERVICE_NAME=beta)))",
      "",
    }, "\n")
    local wallet_dir = create_wallet_fixture(env.temp_dir, wallet_contents, false)
    local wallet_zip = create_wallet_fixture(env.temp_dir, wallet_contents, true)

    local dir_wizard = env.connection_wizard.open({
      title = "Wallet Dir",
      seed = {
        params = {
          name = "Wallet Dir",
          type = "oracle",
          url = "",
        },
        wizard = {
          db_kind = "oracle",
          mode = "oracle_cloud_wallet",
          fields = {
            name = "Wallet Dir",
            wallet_path = wallet_dir,
            service_alias = "",
            username = "scott",
            password = "tiger",
          },
        },
      },
    })
    assert_true("wallet dir aliases discovered", contains(dir_wizard.state.wallet_aliases, "ALPHA_LOW"))
    env.runtime.next_select_choice = "ALPHA_LOW"
    dir_wizard:edit_field({
      key = "service_alias",
      label = "Service Alias",
      kind = "text",
    })
    assert_eq("wallet dir alias selected", dir_wizard:current_fields().service_alias, "ALPHA_LOW")
    dir_wizard:close()

    local zip_wizard = env.connection_wizard.open({
      title = "Wallet Zip",
      seed = {
        params = {
          name = "Wallet Zip",
          type = "oracle",
          url = "",
        },
        wizard = {
          db_kind = "oracle",
          mode = "oracle_cloud_wallet",
          fields = {
            name = "Wallet Zip",
            wallet_path = wallet_zip,
            service_alias = "",
            username = "scott",
            password = "tiger",
          },
        },
      },
    })
    assert_true("wallet zip aliases discovered", contains(zip_wizard.state.wallet_aliases, "BETA"))
    zip_wizard:close()
    print("DCFG02_WALLET_ALIAS_DISCOVERY_OK=true")
  end

  do
    local broken_wallet = vim.fs.joinpath(env.temp_dir, "broken_wallet")
    vim.fn.mkdir(broken_wallet, "p")
    local broken_tns = vim.fs.joinpath(broken_wallet, "tnsnames.ora")
    local broken_fd = assert(io.open(broken_tns, "w"))
    broken_fd:write("BROKEN = (DESCRIPTION=")
    broken_fd:close()

    local malformed_aliases, malformed_map = env.connection_wizard._parse_wallet_aliases("BROKEN = (DESCRIPTION=")
    assert_eq("malformed aliases empty", #malformed_aliases, 0)
    assert_eq("malformed alias map empty", vim.tbl_count(malformed_map), 0)

    local wizard = env.connection_wizard.open({
      title = "Wallet Fallback",
      seed = {
        params = {
          name = "Wallet Fallback",
          type = "oracle",
          url = "",
        },
        wizard = {
          db_kind = "oracle",
          mode = "oracle_cloud_wallet",
          fields = {
            name = "Wallet Fallback",
            wallet_path = broken_wallet,
            service_alias = "",
            username = "scott",
            password = "tiger",
          },
        },
      },
    })
    assert_eq("wallet fallback aliases empty", #wizard.state.wallet_aliases, 0)
    assert_match("wallet fallback warning", wizard.state.wallet_alias_warning, "manual alias entry remains available")
    env.runtime.next_input_value = "MANUAL_ALIAS"
    wizard:edit_field({
      key = "service_alias",
      label = "Service Alias",
      kind = "text",
    })
    assert_eq("manual alias input", wizard:current_fields().service_alias, "MANUAL_ALIAS")
    assert_true("manual alias input call", last(env.runtime.input_calls) ~= nil)
    wizard:close()
    print("DCFG02_WALLET_ALIAS_FALLBACK_OK=true")
  end

  do
    clear_runtime_observations(env.runtime)
    local node = {
      id = "conn-meta",
      name = "Meta PG",
      type = "connection",
    }
    env.convert.decorate_connection_node(node, env.handler, file_source_meta, "conn-meta", {
      open_edit_connection = function(source_meta, target_conn_id, on_done)
        env.drawer:open_edit_connection_with_wizard(source_meta, target_conn_id, nil, on_done)
      end,
    })
    local wizard = expect_wizard(env, function()
      node.action_2(function() end)
    end)
    assert_eq("filter edit seam mode", wizard.state.mode, "postgres_url")
    assert_eq("filter edit seam source", env.runtime.last_wizard_open.source_id, file_source_meta.id)
    assert_eq("legacy raw prompt removed", #env.runtime.prompt_calls, 0)
    wizard:close()
    print("DCFG02_EDIT_SEAM_CONSISTENT_OK=true")
  end

  do
    clear_runtime_observations(env.runtime)
    Harness.set_current_node(env.winid, env.drawer.tree, "conn-meta")
    env.runtime.next_select_choice = "Edit source file"
    env.drawer:get_actions().edit_connection()
    Harness.drain()
    local editor_call = last(env.runtime.editor_calls)
    assert_true("source file editor call present", editor_call ~= nil)
    assert_eq("source file editor path", editor_call.path, env.file_path)
    print("DCFG02_SOURCE_EDIT_SECONDARY_OK=true")
  end

  env:cleanup()
end

local function run_local_validation_contract()
  local env = new_env()

  local submits = 0
  local wizard = env.connection_wizard.open({
    title = "Local Validation",
    seed = {
      params = {
        name = "Broken",
        type = "postgres",
        url = "",
      },
      wizard = {
        db_kind = "postgres",
        mode = "postgres_form",
        fields = {
          name = "Broken",
          host = "",
          port = "not-a-port",
          database = "",
          username = "",
          password = "",
          sslmode = "",
        },
      },
    },
    on_submit = function()
      submits = submits + 1
      return nil
    end,
  })

  local submission, errors = wizard:submit()
  assert_eq("local validation submission", submission, nil)
  assert_true("local validation errors", type(errors) == "table" and #errors > 0)
  assert_eq("local validation submit callback", submits, 0)
  assert_eq("local validation ping calls", #env.runtime.connection_test_spec_calls, 0)
  assert_match("local validation error message", wizard.state.last_error, "Host is required.")
  wizard:close()

  local multiline_descriptor = table.concat({
    "(",
    "  DESCRIPTION=",
    "    (ADDRESS=(PROTOCOL=tcp)(HOST=oracle-host)(PORT=1521))",
    "    (CONNECT_DATA=(SERVICE_NAME=XE))",
    ")",
  }, "\n")
  local oracle_submits = 0
  local oracle_wizard = env.connection_wizard.open({
    title = "Oracle Validation",
    seed = {
      params = {
        name = "Oracle JDBC",
        type = "oracle",
        url = "",
      },
      wizard = {
        db_kind = "oracle",
        mode = "oracle_custom_jdbc",
        fields = {
          name = "Oracle JDBC",
          username = "scott",
          password = "tiger",
          descriptor = multiline_descriptor,
        },
      },
    },
    on_submit = function(submission)
      oracle_submits = oracle_submits + 1
      assert_eq("oracle descriptor preserved", submission.wizard.fields.descriptor, multiline_descriptor)
      return nil
    end,
  })

  local oracle_submission, oracle_errors = oracle_wizard:submit()
  assert_true("oracle descriptor submission", oracle_submission ~= nil)
  assert_eq("oracle descriptor errors", oracle_errors, nil)
  assert_eq("oracle descriptor submit callback", oracle_submits, 1)
  env:cleanup()
  print("DCFG02_LOCAL_VALIDATION_OK=true")
end

local function run_postgres_form_encoding_contract()
  local env = new_env({
    current_conn_id = "conn-meta",
  })

  clear_runtime_observations(env.runtime)
  local wizard = expect_wizard(env, function()
    env.drawer:open_add_connection_with_wizard(env:file_source_meta(), {
      type = "postgres",
    })
  end)
  wizard:set_mode("postgres_form")
  wizard:set_field("name", "Encoded PG")
  wizard:set_field("host", "encoded-host")
  wizard:set_field("port", "5432")
  wizard:set_field("database", "db/name?#")
  wizard:set_field("username", "user:name")
  wizard:set_field("password", "pa/ss:@?#")
  wizard:set_field("sslmode", "require")
  submit_and_assert_success(wizard)

  local expected_url = "postgres://user%3Aname:pa%2Fss%3A%40%3F%23@encoded-host:5432/db%2Fname%3F%23?sslmode=require"
  local persisted = find_record_by_name(read_json(env.file_path), "Encoded PG")
  assert_true("encoded postgres record exists", persisted ~= nil)
  assert_eq("encoded postgres url", persisted.url, expected_url)
  assert_eq("encoded postgres metadata username", persisted.wizard.fields.username, "user:name")
  assert_eq("encoded postgres metadata password", persisted.wizard.fields.password, "pa/ss:@?#")
  assert_eq("encoded postgres metadata database", persisted.wizard.fields.database, "db/name?#")

  local reopened = expect_wizard(env, function()
    env.drawer:open_edit_connection_with_wizard(env:file_source_meta(), persisted.id)
  end)
  assert_eq("encoded reopen mode", reopened.state.mode, "postgres_form")
  assert_eq("encoded reopen username", reopened:current_fields().username, "user:name")
  assert_eq("encoded reopen password", reopened:current_fields().password, "pa/ss:@?#")
  assert_eq("encoded reopen database", reopened:current_fields().database, "db/name?#")
  reopened:close()
  env:cleanup()
end

local function run_postgres_url_runtime_contract()
  local env = new_env({
    current_conn_id = "conn-meta",
  })

  local cases = {
    {
      name = "PG URL No DB",
      url = "postgres://user:pass@db-host?sslmode=require",
    },
    {
      name = "PG URL Upper",
      url = "POSTGRES://user:pass@db-host/db?sslmode=require",
    },
    {
      name = "PG URL Mixed",
      url = "Postgresql://user:pass@db-host/db",
    },
  }

  for _, case in ipairs(cases) do
    clear_runtime_observations(env.runtime)
    local wizard = expect_wizard(env, function()
      env.drawer:open_add_connection_with_wizard(env:file_source_meta(), {
        type = "postgres",
      })
    end)
    wizard:set_mode("postgres_url")
    wizard:set_field("name", case.name)
    wizard:set_field("url", case.url)
    submit_and_assert_success(wizard)

    assert_true("pg runtime ping called", #env.runtime.connection_test_spec_calls == 1)
    assert_eq("pg runtime ping url", env.runtime.connection_test_spec_calls[1].url, case.url)

    local persisted = find_record_by_name(read_json(env.file_path), case.name)
    assert_true("pg runtime record exists", persisted ~= nil)
    assert_eq("pg runtime url persisted", persisted.url, case.url)
    assert_eq("pg runtime mode persisted", persisted.wizard.mode, "postgres_url")
    assert_eq("pg runtime url metadata", persisted.wizard.fields.url, case.url)

    local reopened = expect_wizard(env, function()
      env.drawer:open_edit_connection_with_wizard(env:file_source_meta(), persisted.id)
    end)
    assert_eq("pg runtime reopen mode", reopened.state.mode, "postgres_url")
    assert_eq("pg runtime reopen url", reopened:current_fields().url, case.url)
    reopened:close()
  end

  env:cleanup()
  print("DCFG02_PG_URL_RUNTIME_COMPAT_OK=true")
end

local function fill_postgres_form(wizard, fields)
  wizard:set_mode("postgres_form")
  for key, value in pairs(fields or {}) do
    wizard:set_field(key, value)
  end
end

local function fill_other_raw(wizard, fields)
  wizard:set_db_kind("other")
  for key, value in pairs(fields or {}) do
    wizard:set_field(key, value)
  end
end

local function run_transient_ping_and_fail_closed_contracts()
  do
    local env = new_env({
      current_conn_id = "conn-meta",
    })

    clear_runtime_observations(env.runtime)
    local wizard = expect_wizard(env, function()
      env.drawer:open_add_connection_with_wizard(env:file_source_meta(), {
        type = "postgres",
      })
    end)
    fill_postgres_form(wizard, {
      name = "Added PG",
      host = "added-host",
      port = "5432",
      database = "added_db",
      username = "added_user",
      password = "added_pass",
      sslmode = "require",
    })
    submit_and_assert_success(wizard)

    assert_true("transient ping called", #env.runtime.connection_test_spec_calls == 1)
    local ping_index = index_of(env.runtime.call_order, "ping")
    local create_index = index_of(env.runtime.call_order, "file:create")
    assert_true("transient ping before create", ping_index ~= nil and create_index ~= nil and ping_index < create_index)
    assert_eq("no auto activate keeps current", env.runtime.current_conn_id, "conn-meta")

    env:cleanup()
    print("DCFG02_TRANSIENT_PING_OK=true")
  end

  do
    local env = new_env({
      current_conn_id = "conn-meta",
    })

    local before = read_json(env.file_path)
    clear_runtime_observations(env.runtime)
    env.runtime.connection_test_spec_failure = {
      error_kind = "network",
      message = "ping failed",
    }

    local wizard = expect_wizard(env, function()
      env.drawer:open_add_connection_with_wizard(env:file_source_meta(), {
        type = "postgres",
      })
    end)
    fill_postgres_form(wizard, {
      name = "Rejected PG",
      host = "reject-host",
      port = "5432",
      database = "reject_db",
      username = "reject_user",
      password = "reject_pass",
      sslmode = "require",
    })

    local submission = wizard:submit()
    assert_eq("fail closed submission", submission, nil)
    assert_match("fail closed error", wizard.state.last_error, "ping failed")
    assert_eq("fail closed current", env.runtime.current_conn_id, "conn-meta")
    assert_eq("fail closed no invalidation", #env.runtime.connection_invalidated_events, 0)
    assert_eq("fail closed file unchanged", vim.inspect(read_json(env.file_path)), vim.inspect(before))
    wizard:close()
    env:cleanup()
    print("DCFG02_FAIL_CLOSED_CURRENT_OK=true")
  end
end

local function run_other_mode_contracts()
  local env = new_env({
    current_conn_id = "conn-meta",
  })

  clear_runtime_observations(env.runtime)
  env.runtime.connection_test_spec_failure = {
    error_kind = "network",
    message = "raw ping blocked",
  }
  local failed_wizard = expect_wizard(env, function()
    env.drawer:open_add_connection_with_wizard(env:raw_source_meta(), {
      type = "mysql",
      url = "mysql://root@localhost/raw_db",
    })
  end)
  fill_other_raw(failed_wizard, {
    name = "Raw Failed",
    type = "mysql",
    url = "mysql://root@localhost/raw_db",
  })
  local submission = failed_wizard:submit()
  assert_eq("other mode failure submission", submission, nil)
  assert_match("other mode failure error", failed_wizard.state.last_error, "raw ping blocked")
  assert_eq("other mode no raw mutation", #env.raw_source.create_calls, 0)
  failed_wizard:close()
  print("DCFG02_OTHER_MODE_PING_GATED_OK=true")

  clear_runtime_observations(env.runtime)
  local success_wizard = expect_wizard(env, function()
    env.drawer:open_add_connection_with_wizard(env:raw_source_meta(), {
      type = "mysql",
      url = "mysql://root@localhost/raw_ok",
    })
  end)
  fill_other_raw(success_wizard, {
    name = "Raw Success",
    type = "mysql",
    url = "mysql://root@localhost/raw_ok",
  })
  submit_and_assert_success(success_wizard)
  assert_true("raw create call present", #env.raw_source.create_calls == 1)
  assert_eq("non filesource wizard stripped", env.raw_source.create_calls[1].wizard, nil)
  env:cleanup()
  print("DCFG02_NON_FILESOURCE_NO_METADATA_OK=true")
end

local function run_filesource_raw_fallback_contract()
  local env = new_env({
    current_conn_id = "conn-meta",
  })

  clear_runtime_observations(env.runtime)
  local wizard = expect_wizard(env, function()
    env.drawer:open_edit_connection_with_wizard(env:file_source_meta(), "conn-meta")
  end)
  wizard:set_field("url", "postgres://meta_user:meta_pass@meta-host:5432/meta_db?sslmode=require&application_name=nvim-dbee")
  wizard:set_mode("postgres_form")
  wizard:set_mode("postgres_url")
  assert_true("unsupported postgres derived raw fallback", wizard.state.raw_fallback == true)
  submit_and_assert_success(wizard)

  local persisted = find_record(read_json(env.file_path), "conn-meta")
  assert_true("raw fallback record persisted", persisted ~= nil)
  assert_eq("wizard metadata removed", persisted.wizard, nil)
  assert_true("remove keys sent", env.file_source.update_calls[1].details.__remove_keys ~= nil)

  clear_runtime_observations(env.runtime)
  local reopened = expect_wizard(env, function()
    env.drawer:open_edit_connection_with_wizard(env:file_source_meta(), "conn-meta")
  end)
  assert_eq("reopened unsupported mode", reopened.state.mode, "postgres_url")
  assert_true("reopened unsupported raw fallback", reopened.state.raw_fallback == true)
  reopened:set_field("url", "postgres://meta_user:meta_pass@meta-host:5432/meta_db?sslmode=require")
  reopened:set_mode("postgres_form")
  reopened:set_mode("postgres_url")
  assert_true("supported postgres clears raw fallback", reopened.state.raw_fallback == false)
  submit_and_assert_success(reopened)

  local restored = find_record(read_json(env.file_path), "conn-meta")
  assert_true("restored wizard metadata", restored.wizard ~= nil)
  assert_eq("restored wizard mode", restored.wizard.mode, "postgres_url")
  assert_eq("restored wizard url", restored.wizard.fields.url, "postgres://meta_user:meta_pass@meta-host:5432/meta_db?sslmode=require")
  assert_eq("restored remove keys omitted", env.file_source.update_calls[2].details.__remove_keys, nil)
  env:cleanup()
  print("DCFG02_FILESOURCE_RAW_FALLBACK_NO_METADATA_OK=true")
end

local function run_missing_filesource_edit_failure_contract()
  local env = new_env({
    current_conn_id = "conn-meta",
  })

  clear_runtime_observations(env.runtime)
  local wizard = expect_wizard(env, function()
    env.drawer:open_edit_connection_with_wizard(env:file_source_meta(), "conn-meta")
  end)

  env.file_source:delete("conn-meta")
  local after_delete = read_json(env.file_path)

  fill_postgres_form(wizard, {
    name = "Vanished PG",
    host = "vanished-host",
    port = "5432",
    database = "vanished_db",
    username = "vanished_user",
    password = "vanished_pass",
    sslmode = "require",
  })

  local submission = wizard:submit()
  Harness.drain()
  assert_eq("missing row submission", submission, nil)
  assert_match("missing row error", wizard.state.last_error, "connection id not found")
  assert_eq("missing row no invalidation", #env.runtime.connection_invalidated_events, 0)
  assert_eq("missing row file unchanged", vim.inspect(read_json(env.file_path)), vim.inspect(after_delete))

  wizard:close()
  env:cleanup()
end

local function run_unknown_wizard_mode_contract()
  local original_wizard = {
    db_kind = "postgres",
    mode = "postgres_future",
    custom_unknown_key = "preserve_top",
    fields = {
      name = "Future PG",
      url = "postgres://future_user:future_pass@future-host:5432/future_db?sslmode=require",
      custom_unknown_key = "preserve_me",
    },
  }
  local file_records = default_file_records()
  file_records[#file_records + 1] = {
    id = "conn-future-unchanged",
    name = "Future PG",
    type = "postgres",
    url = "postgres://future_user:future_pass@future-host:5432/future_db?sslmode=require",
    wizard = vim.deepcopy(original_wizard),
  }
  file_records[#file_records + 1] = {
    id = "conn-future-edited",
    name = "Future PG Edited",
    type = "postgres",
    url = "postgres://future_user:future_pass@future-host:5432/future_db?sslmode=require",
    wizard = vim.deepcopy(original_wizard),
  }
  local env = new_env({
    current_conn_id = "conn-meta",
    file_records = file_records,
  })

  clear_runtime_observations(env.runtime)
  local unchanged = expect_wizard(env, function()
    env.drawer:open_edit_connection_with_wizard(env:file_source_meta(), "conn-future-unchanged")
  end)
  assert_eq("unknown mode fallback", unchanged.state.mode, "other_raw")
  assert_eq("unknown mode type", unchanged:current_fields().type, "postgres")
  assert_eq(
    "unknown mode url",
    unchanged:current_fields().url,
    "postgres://future_user:future_pass@future-host:5432/future_db?sslmode=require"
  )
  submit_and_assert_success(unchanged)
  local unchanged_record = find_record(read_json(env.file_path), "conn-future-unchanged")
  assert_eq("unknown mode unchanged wizard", vim.inspect(unchanged_record.wizard), vim.inspect(original_wizard))
  assert_eq("unknown mode no delete directive", env.file_source.update_calls[1].details.__remove_keys, nil)
  assert_eq("unknown mode no replacement wizard", env.file_source.update_calls[1].details.wizard, nil)

  clear_runtime_observations(env.runtime)
  local edited = expect_wizard(env, function()
    env.drawer:open_edit_connection_with_wizard(env:file_source_meta(), "conn-future-edited")
  end)
  assert_eq("unknown mode edited fallback", edited.state.mode, "other_raw")
  edited:set_field("name", "Future PG Renamed")
  submit_and_assert_success(edited)
  local edited_record = find_record(read_json(env.file_path), "conn-future-edited")
  assert_eq("unknown mode edited name", edited_record.name, "Future PG Renamed")
  assert_eq("unknown mode preserved mode", edited_record.wizard.mode, "postgres_future")
  assert_eq("unknown mode preserved top-level key", edited_record.wizard.custom_unknown_key, "preserve_top")
  assert_eq("unknown mode preserved nested key", edited_record.wizard.fields.custom_unknown_key, "preserve_me")

  env:cleanup()
  print("DCFG02_UNKNOWN_WIZARD_MODE_PRESERVED_OK=true")
end

local function run_partial_failure_contract()
  local env = new_env({
    current_conn_id = false,
  })

  env.handler:connection_clear_current()
  clear_runtime_observations(env.runtime)
  env.file_source.fail_next_load = "reload exploded"

  local wizard = expect_wizard(env, function()
    env.drawer:open_edit_connection_with_wizard(env:file_source_meta(), "conn-form")
  end)
  fill_postgres_form(wizard, {
    name = "Form PG Reload Fail",
    host = "reload-host",
    port = "5432",
    database = "reload_db",
    username = "reload_user",
    password = "reload_pass",
    sslmode = "require",
  })
  local submission = wizard:submit()
  Harness.drain()
  assert_eq("partial failure submission", submission, nil)
  assert_match("partial failure error", wizard.state.last_error, "reload exploded")

  local invalidated = latest_connection_invalidated(env.runtime, "source_update")
  local reload_failed = latest_source_reload_failed(env.runtime, "source_update")
  assert_true("partial failure invalidated emitted: " .. vim.inspect(env.runtime.connection_invalidated_events), invalidated ~= nil)
  assert_true("partial failure reload failed emitted: " .. vim.inspect(env.runtime.source_reload_failed_events), reload_failed ~= nil)
  assert_eq("partial failure current nil", env.runtime.current_conn_id, nil)
  assert_eq("partial failure event current nil", invalidated.current_conn_id_after, nil)
  assert_eq("partial failure no transient activation", #env.runtime.current_connection_changed_events, 0)
  assert_eq("partial failure reload stage", reload_failed.stage, "reload")

  local persisted = find_record(read_json(env.file_path), "conn-form")
  assert_eq("partial failure persisted name", persisted.name, "Form PG Reload Fail")
  wizard:close()
  env:cleanup()
  print("DCFG02_D83_PARTIAL_FAILURE_OK=true")
end

local function run_no_auto_activate_contract()
  do
    local env = new_env({
      current_conn_id = "conn-meta",
    })

    clear_runtime_observations(env.runtime)
    local wizard = expect_wizard(env, function()
      env.drawer:open_add_connection_with_wizard(env:file_source_meta(), {
        type = "postgres",
      })
    end)
    fill_postgres_form(wizard, {
      name = "No Activate A",
      host = "no-activate-a",
      port = "5432",
      database = "db_a",
      username = "user_a",
      password = "pass_a",
      sslmode = "require",
    })
    submit_and_assert_success(wizard)
    local event = latest_connection_invalidated(env.runtime, "source_add")
    assert_eq("current preserved on add", env.runtime.current_conn_id, "conn-meta")
    assert_eq("event current preserved on add", event.current_conn_id_after, "conn-meta")
    env:cleanup()
  end

  do
    local env = new_env({
      current_conn_id = false,
    })

    env.handler:connection_clear_current()
    clear_runtime_observations(env.runtime)
    local wizard = expect_wizard(env, function()
      env.drawer:open_add_connection_with_wizard(env:file_source_meta(), {
        type = "postgres",
      })
    end)
    fill_postgres_form(wizard, {
      name = "No Activate Nil",
      host = "no-activate-nil",
      port = "5432",
      database = "db_nil",
      username = "user_nil",
      password = "pass_nil",
      sslmode = "require",
    })
    submit_and_assert_success(wizard)
    local event = latest_connection_invalidated(env.runtime, "source_add")
    assert_eq("nil current preserved", env.runtime.current_conn_id, nil)
    assert_eq("event nil current preserved", event.current_conn_id_after, nil)
    assert_eq("nil current no transient activation", #env.runtime.current_connection_changed_events, 0)
    env:cleanup()
  end

  print("DCFG02_NO_AUTO_ACTIVATE_OK=true")
end

local function run_wizard_highlight_contract()
  local function open_highlight_wizard(label, configure_highlights)
    if configure_highlights then
      configure_highlights()
    end

    local env = new_env({
      current_conn_id = "conn-meta",
    })
    local wizard = expect_wizard(env, function()
      env.drawer:open_add_connection_with_wizard(env:file_source_meta(), {
        type = "postgres",
      })
    end)
    assert_winhighlight(label .. "_main", wizard.popup.opts)
    assert_buffer_contains(label .. "_main_text", wizard.popup.bufnr, "Type: Postgres")
    return env, wizard
  end

  local env, wizard = open_highlight_wizard("ux13_bright", function()
    vim.o.background = "light"
    pcall(vim.cmd.colorscheme, "default")
  end)

  wizard:edit_type()
  assert_eq("type select winhighlight", last(env.runtime.select_calls).winhighlight, UX13_WIZARD_WINHIGHLIGHT)
  wizard:edit_mode()
  assert_eq("mode select winhighlight", last(env.runtime.select_calls).winhighlight, UX13_WIZARD_WINHIGHLIGHT)

  wizard:edit_field({ key = "sslmode", label = "SSL Mode", kind = "select", options = { "disable", "require" } })
  assert_eq("field select winhighlight", last(env.runtime.select_calls).winhighlight, UX13_WIZARD_WINHIGHLIGHT)

  wizard:set_field("name", "Visible Wizard Text")
  wizard:edit_field({ key = "name", label = "Name", kind = "text" })
  local input_call = last(env.runtime.input_calls)
  assert_eq("text input winhighlight", input_call.winhighlight, UX13_WIZARD_WINHIGHLIGHT)
  assert_eq("text input default preserved", input_call.default_value, "Visible Wizard Text")

  wizard:set_field("password", "secret-value")
  wizard:edit_field({ key = "password", label = "Password", kind = "password" })
  local password_popup = last(env.runtime.active_popups)
  assert_winhighlight("password input winhighlight", password_popup.opts)
  assert_eq("password input default preserved", password_popup.input_opts.default_value, "secret-value")

  wizard:set_mode("oracle_custom_jdbc")
  wizard:set_field("descriptor", "DESCRIPTION=visible-descriptor")
  wizard:edit_field({ key = "descriptor", label = "Descriptor", kind = "multiline" })
  local multiline_popup = last(env.runtime.active_popups)
  assert_winhighlight("multiline popup winhighlight", multiline_popup.opts)
  assert_buffer_contains("multiline text render state", multiline_popup.bufnr, "visible-descriptor")
  env:cleanup()
  print("UX13_WIZARD_BRIGHT_BASELINE_OK=true")

  env, wizard = open_highlight_wizard("ux13_dark_collision", function()
    vim.o.background = "dark"
    vim.api.nvim_set_hl(0, "Normal", { fg = "#101010", bg = "#101010" })
    vim.api.nvim_set_hl(0, "NormalFloat", { fg = "#f0f0f0", bg = "#202020" })
    vim.api.nvim_set_hl(0, "FloatBorder", { fg = "#f0f0f0", bg = "#202020" })
    vim.api.nvim_set_hl(0, "FloatTitle", { fg = "#ffffff", bg = "#202020" })
  end)
  assert_buffer_contains("dark collision text render state", wizard.popup.bufnr, "Type: Postgres")
  env:cleanup()
  print("UX13_WIZARD_DARK_COLLISION_OK=true")

  local daily = vim.env.DBEE_UX13_COLORSCHEME
  if daily and daily ~= "" then
    local ok = pcall(vim.cmd.colorscheme, daily)
    if ok then
      env, wizard = open_highlight_wizard("ux13_daily")
      assert_buffer_contains("daily colorscheme text render state", wizard.popup.bufnr, "Type: Postgres")
      env:cleanup()
    end
  end

  print("UX13_WIZARD_WINHIGHLIGHT_MAIN=true")
  print("UX13_WIZARD_WINHIGHLIGHT_PASSWORD=true")
  print("UX13_WIZARD_WINHIGHLIGHT_INPUT=true")
  print("UX13_WIZARD_WINHIGHLIGHT_SELECT=true")
  print("UX13_WIZARD_WINHIGHLIGHT_MULTILINE=true")
  print("UX13_WIZARD_TEXT_RENDER_STATE_OK=true")
  print("UX13_WIZARD_ALL_PASS=true")
end

run_navigation_and_seed_contracts()
run_local_validation_contract()
run_postgres_form_encoding_contract()
run_postgres_url_runtime_contract()
run_transient_ping_and_fail_closed_contracts()
run_other_mode_contracts()
run_filesource_raw_fallback_contract()
run_missing_filesource_edit_failure_contract()
run_unknown_wizard_mode_contract()
run_partial_failure_contract()
run_no_auto_activate_contract()
run_wizard_highlight_contract()

print("DCFG02_WIZARD_ALL_PASS=true")

vim.notify = saved_notify
vim.cmd("qa!")
